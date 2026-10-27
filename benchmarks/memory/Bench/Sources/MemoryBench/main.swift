import Dispatch
import Foundation
import MosaicCore

// Runs the app's real HybridMemoryRetriever over the synthetic personal-memory benchmark.
// Usage: MemoryBench <work-dir> <label>   (writes <work-dir>/results.<label>.json)

struct Dataset: Decodable {
  struct Item: Decodable {
    let id: String
    let persona: String
    let kind: String
    let text: String
    let ageDays: Double
    let confidence: Double?
    let importance: Double?
    let container: String

    enum CodingKeys: String, CodingKey {
      case id, persona, kind, text, confidence, importance, container
      case ageDays = "age_days"
    }
  }
  struct Query: Decodable {
    let id: String
    let persona: String
    let type: String
    let lang: String
    let text: String
    let gold: [String]
  }
  let personas: [String]
  let items: [Item]
  let queries: [Query]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError.write(Data("usage: MemoryBench <work-dir> <label>\n".utf8))
  exit(2)
}
let work = arguments[1]
let label = arguments[2]
let dataset = try JSONDecoder().decode(
  Dataset.self, from: Data(contentsOf: URL(fileURLWithPath: "\(work)/dataset.json")))
let environment = ProcessInfo.processInfo.environment
// Counterfactual aging: shift every event's age to test how the fade policy treats old events.
let eventShift = Double(environment["MB_EVENT_SHIFT"] ?? "") ?? 0
// MB_FADE = "halfLifeDays:floor:protectedRanks:protectedWeight" (default: the app's standard policy).
let eventFade: EventFadePolicy = {
  guard let spec = environment["MB_FADE"] else { return .standard }
  let parts = spec.split(separator: ":").compactMap { Double($0) }
  guard parts.count >= 2 else { return .legacy }
  return EventFadePolicy(
    halfLifeDays: parts[0], floor: parts[1], protectedRanks: parts.count > 2 ? Int(parts[2]) : 0,
    protectedWeight: parts.count > 3 ? parts[3] : 1)
}()
let itemCount = dataset.items.count
let queryCount = dataset.queries.count

// Every work/scores/<model>.f32 file is a model; MB_MODELS limits the set.
let allModels: [String] = {
  let files = (try? FileManager.default.contentsOfDirectory(atPath: "\(work)/scores")) ?? []
  let found = files.filter { $0.hasSuffix(".f32") }.map { String($0.dropLast(4)) }.sorted()
  guard let wanted = environment["MB_MODELS"]?.split(separator: ",").map(String.init) else {
    return found
  }
  return found.filter { wanted.contains($0) }
}()
var matrices: [String: [Float]] = [:]
for model in allModels {
  let data = try Data(contentsOf: URL(fileURLWithPath: "\(work)/scores/\(model).f32"))
  precondition(data.count == queryCount * itemCount * MemoryLayout<Float>.size, "bad score size")
  matrices[model] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

struct Rerank {
  let label: String
  let tau: Double
  let blend: Bool
}
struct Configuration {
  let name: String
  let profiles: [(model: String, weight: Double)]
  var rerank: Rerank?
}
var configurations = [Configuration(name: "local-only", profiles: [], rerank: nil)]
for model in allModels {
  configurations.append(Configuration(name: model, profiles: [(model, 1.0)], rerank: nil))
}
// MB_FUSIONS = comma-separated fusions, each "modelA+modelB*0.5+modelC" (weight defaults to 1).
let defaultFusions = [
  "bge-m3+qwen3-emb-0.6b", "nomic-v1.5+bge-m3", "nomic-v1.5+qwen3-emb-0.6b",
  "nomic-v1.5+bge-m3+qwen3-emb-0.6b", "nomic-v1.5*0.1+bge-m3+qwen3-emb-0.6b",
]
let fusionSpecs =
  environment["MB_FUSIONS"]?.split(separator: ",").map(String.init) ?? defaultFusions
for spec in fusionSpecs {
  let profiles: [(model: String, weight: Double)] = spec.split(separator: "+").map { part in
    let pieces = part.split(separator: "*")
    return (String(pieces[0]), pieces.count > 1 ? Double(pieces[1]) ?? 1 : 1)
  }
  guard profiles.allSatisfy({ allModels.contains($0.model) }) else { continue }
  configurations.append(Configuration(name: spec, profiles: profiles, rerank: nil))
}

// MB_PIPELINES = comma-separated "firstStage>>reranker~tau": the first stage's top 20 are scored by the
// reranker (work/rerank/<reranker>.f32; raw logits are squashed to probabilities), candidates scoring
// below tau are dropped, and survivors are selected by reranker score (HybridMemoryRetriever.select).
// A "blend:" prefix instead feeds the reranker through the blended semantic term.
var rerankMatrices: [String: [Float]] = [:]
func probabilityMatrix(_ label: String) -> [Float]? {
  if let cached = rerankMatrices[label] { return cached }
  let url = URL(fileURLWithPath: "\(work)/rerank/\(label).f32")
  guard let data = try? Data(contentsOf: url) else { return nil }
  var values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  if values.contains(where: { $0.isFinite && ($0 < 0 || $0 > 1) }) {
    values = values.map { $0.isFinite ? 1 / (1 + exp(-$0)) : $0 }
  }
  rerankMatrices[label] = values
  return values
}
for spec in environment["MB_PIPELINES"]?.split(separator: ",").map(String.init) ?? [] {
  let blend = spec.hasPrefix("blend:")
  let halves = (blend ? String(spec.dropFirst(6)) : spec).components(separatedBy: ">>")
  guard halves.count == 2, let second = halves.last else { continue }
  let tail = second.components(separatedBy: "~")
  let label = tail[0]
  let tau = tail.count > 1 ? Double(tail[1]) ?? 0 : 0
  let profiles: [(model: String, weight: Double)] = halves[0].split(separator: "+").map { part in
    let pieces = part.split(separator: "*")
    return (String(pieces[0]), pieces.count > 1 ? Double(pieces[1]) ?? 1 : 1)
  }
  let known = profiles.allSatisfy { allModels.contains($0.model) }
  guard known, probabilityMatrix(label) != nil else { continue }
  let rerank = Rerank(label: label, tau: tau, blend: blend)
  configurations.append(Configuration(name: spec, profiles: profiles, rerank: rerank))
}

if let wanted = environment["MB_CONFIGS"]?.split(separator: ",").map(String.init) {
  configurations = configurations.filter { wanted.contains($0.name) }
}
let anchor = Date()
var containerIDs: [String: UUID] = [:]
var itemIDs: [UUID] = []
var candidatesAll: [RetrievalCandidate] = []
for (index, item) in dataset.items.enumerated() {
  let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
  itemIDs.append(id)
  let container: UUID
  if let existing = containerIDs[item.container] {
    container = existing
  } else {
    let number = containerIDs.count
    container = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!
    containerIDs[item.container] = container
  }
  let age = item.ageDays + (item.kind == "event" ? eventShift : 0)
  let created = anchor.addingTimeInterval(-age * 86_400)
  let source: RetrievalSourceKind
  var kind: MemoryTopicKind?
  switch item.kind {
  case "topic":
    source = .memoryTopic
    kind = .identity
  case "event":
    source = .memoryTopic
    kind = .event
  case "document": source = .documentChunk
  default: source = .conversationMessage
  }
  candidatesAll.append(
    RetrievalCandidate(
      id: id, source: source, containerID: container, title: "", content: item.text,
      memoryConfidence: item.confidence, memoryImportance: item.importance, memoryKind: kind,
      memoryLastConfirmedAt: kind == nil ? nil : created, createdAt: created))
}

let itemIndex: [UUID: Int] = Dictionary(
  uniqueKeysWithValues: itemIDs.enumerated().map { ($0.element, $0.offset) })
let rankingRetriever = HybridMemoryRetriever(
  referenceDate: anchor, maximumItems: 20, maximumCharacters: 100_000_000,
  maximumItemsPerContainer: 20, eventFade: eventFade)
let appRetriever = HybridMemoryRetriever(referenceDate: anchor, eventFade: eventFade)

struct Stores {
  let name: String
  let columns: (Int) -> [Int]  // item indices that form the store for a query
}
let personaColumns: [String: [Int]] = Dictionary(
  grouping: dataset.items.indices, by: { dataset.items[$0].persona })
let stores = [
  Stores(name: "per-persona", columns: { personaColumns[dataset.queries[$0].persona]! }),
  Stores(name: "pooled", columns: { _ in Array(0..<itemCount) }),
]

struct ConfigResult: Encodable {
  let rank: [Int]
  let returned: [Int]
  let injected: [Int]
  let top: [Double]
  let candidates: [[Int]]
}
struct Output: Encodable {
  let label: String
  let models: [String]
  let nQueries: Int
  let stores: [String: [String: ConfigResult]]
  let localPool40: [String: [[Int]]]
}
var storeResults: [String: [String: ConfigResult]] = [:]
var localPools: [String: [[Int]]] = [:]
let wantedStores = environment["MB_STORES"]?.split(separator: ",").map(String.init)
for store in stores where wantedStores?.contains(store.name) ?? true {
  let started = Date()
  let configCount = configurations.count
  let rank = UnsafeMutablePointer<Int>.allocate(capacity: configCount * queryCount)
  let returned = UnsafeMutablePointer<Int>.allocate(capacity: configCount * queryCount)
  let injected = UnsafeMutablePointer<Int>.allocate(capacity: configCount * queryCount)
  let top = UnsafeMutablePointer<Double>.allocate(capacity: configCount * queryCount)
  let firstStage = UnsafeMutablePointer<[Int]>.allocate(capacity: configCount * queryCount)
  firstStage.initialize(repeating: [], count: configCount * queryCount)
  let pools = UnsafeMutablePointer<[Int]>.allocate(capacity: queryCount)
  pools.initialize(repeating: [], count: queryCount)
  rank.initialize(repeating: 0, count: configCount * queryCount)
  returned.initialize(repeating: 0, count: configCount * queryCount)
  injected.initialize(repeating: 0, count: configCount * queryCount)
  top.initialize(repeating: 0, count: configCount * queryCount)

  DispatchQueue.concurrentPerform(iterations: queryCount) { q in
    let query = dataset.queries[q]
    let columns = store.columns(q)
    let candidates = columns.map { candidatesAll[$0] }
    let goldColumns = Set(
      query.gold.compactMap { goldID in dataset.items.firstIndex(where: { $0.id == goldID }) })
    let goldIDs = Set(goldColumns.map { itemIDs[$0] })
    let preparation = rankingRetriever.prepare(
      query: query.text, candidates: candidates, maximumCount: candidates.count)
    let local = preparation.scores
    // The app's smart-memory stage only ever sees the first 40 of this lexical candidate pool.
    pools[q] = preparation.candidatePool.prefix(40).compactMap { itemIndex[$0.id] }
    var perModel: [String: [UUID: Double]] = [:]
    for model in allModels {
      var scores: [UUID: Double] = [:]
      scores.reserveCapacity(columns.count)
      for column in columns {
        scores[itemIDs[column]] = Double(matrices[model]![q * itemCount + column])
      }
      perModel[model] = scores
    }
    for (configIndex, configuration) in configurations.enumerated() {
      var sets = configuration.profiles.map {
        SemanticScoreSet(profileName: $0.model, weight: $0.weight, scores: perModel[$0.model]!)
      }
      var pool = candidates
      var rerankScores: [UUID: Double]?
      if let rerank = configuration.rerank, let matrix = rerankMatrices[rerank.label] {
        let firstStage = rankingRetriever.retrieve(
          query: query.text, candidates: candidates, semanticScoreSets: sets,
          localScoreSnapshot: local
        ).items
        var scores: [UUID: Double] = [:]
        for item in firstStage {
          guard let column = itemIndex[item.id] else { continue }
          let value = matrix[q * itemCount + column]
          if value.isFinite, Double(value) >= rerank.tau { scores[item.id] = Double(value) }
        }
        pool = firstStage.compactMap { item in
          scores[item.id] == nil ? nil : itemIndex[item.id].map { candidatesAll[$0] }
        }
        if rerank.blend {
          sets = [SemanticScoreSet(profileName: rerank.label, weight: 1, scores: scores)]
        } else {
          rerankScores = scores
        }
      }
      let slot = configIndex * queryCount + q
      let ranked =
        rerankScores.map { rankingRetriever.select(rankedBy: $0, from: pool).items }
        ?? rankingRetriever.retrieve(
          query: query.text, candidates: pool, semanticScoreSets: sets,
          localScoreSnapshot: local
        ).items
      if let position = ranked.firstIndex(where: { goldIDs.contains($0.id) }), position < 10 {
        rank[slot] = position + 1
      }
      firstStage[slot] = ranked.compactMap { itemIndex[$0.id] }
      top[slot] = ranked.first?.relevance ?? 0
      let delivered =
        rerankScores.map { appRetriever.select(rankedBy: $0, from: pool).items }
        ?? appRetriever.retrieve(
          query: query.text, candidates: pool, semanticScoreSets: sets,
          localScoreSnapshot: local
        ).items
      returned[slot] = delivered.count
      injected[slot] = delivered.contains(where: { goldIDs.contains($0.id) }) ? 1 : 0
    }
  }

  for slot in 0..<(configCount * queryCount) where !top[slot].isFinite {
    let config = configurations[slot / queryCount].name
    let id = dataset.queries[slot % queryCount].id
    FileHandle.standardError.write(
      Data("non-finite relevance: \(store.name) \(config) \(id) = \(top[slot])\n".utf8))
  }
  var perConfig: [String: ConfigResult] = [:]
  for (configIndex, configuration) in configurations.enumerated() {
    let range = (0..<queryCount).map { configIndex * queryCount + $0 }
    perConfig[configuration.name] = ConfigResult(
      rank: range.map { rank[$0] }, returned: range.map { returned[$0] },
      injected: range.map { injected[$0] }, top: range.map { top[$0] },
      candidates: range.map { firstStage[$0] })
  }
  rank.deallocate()
  returned.deallocate()
  injected.deallocate()
  top.deallocate()
  firstStage.deinitialize(count: configCount * queryCount)
  firstStage.deallocate()
  storeResults[store.name] = perConfig
  localPools[store.name] = (0..<queryCount).map { pools[$0] }
  pools.deinitialize(count: queryCount)
  pools.deallocate()
  let seconds = Int(Date().timeIntervalSince(started))
  print("\(store.name): \(queryCount) queries x \(configurations.count) configs in \(seconds)s")
}
let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
try encoder.encode(
  Output(
    label: label, models: allModels, nQueries: queryCount, stores: storeResults,
    localPool40: localPools)
).write(to: URL(fileURLWithPath: "\(work)/results.\(label).json"))
print("wrote \(work)/results.\(label).json")
