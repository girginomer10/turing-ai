import Dispatch
import Foundation
import MosaicCore

// Runs the app's real HybridMemoryRetriever (local BM25 + hash + concept scoring, reciprocal-rank
// fusion of embedding profiles, relevance gates) over XQuAD with precomputed embedding scores.
// Usage: RetrievalBench <work-dir>

struct Dataset: Decodable {
  struct Question: Decodable {
    let id: String
    let gold: Int
    let tr: String
    let en: String
  }
  let paragraphs: [String: [String]]
  let questions: [Question]
}

struct Setting {
  let name: String
  let queryLanguage: String
  let documentLanguages: [String]
}

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
  FileHandle.standardError.write(Data("usage: RetrievalBench <work-dir>\n".utf8))
  exit(2)
}
let work = arguments[1]
let outputName = arguments.count == 3 ? arguments[2] : "results"
let environment = ProcessInfo.processInfo.environment
let dataset = try JSONDecoder().decode(
  Dataset.self, from: Data(contentsOf: URL(fileURLWithPath: "\(work)/dataset.json")))
let paragraphCount = dataset.paragraphs["tr"]!.count
let queryCount = dataset.questions.count

let scoreDirectory = "\(work)/scores"
// Every work/scores/<model>.tr-tr.f32 file is a model; RB_MODELS limits the set.
let allModels: [String] = {
  let files = (try? FileManager.default.contentsOfDirectory(atPath: scoreDirectory)) ?? []
  let suffix = ".tr-tr.f32"
  let found = files.filter { $0.hasSuffix(suffix) }
    .map { String($0.dropLast(suffix.count)) }.sorted()
  guard let wanted = environment["RB_MODELS"]?.split(separator: ",").map(String.init) else {
    return found
  }
  return found.filter { wanted.contains($0) }
}()
func loadScores(_ model: String, _ pair: String) -> [Float] {
  let data = try! Data(contentsOf: URL(fileURLWithPath: "\(scoreDirectory)/\(model).\(pair).f32"))
  let expected = queryCount * paragraphCount * MemoryLayout<Float>.size
  precondition(data.count == expected, "bad score size")
  return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
var scoreMatrices: [String: [Float]] = [:]
for model in allModels {
  for pair in ["tr-tr", "tr-en", "en-tr", "en-en"] {
    scoreMatrices["\(model).\(pair)"] = loadScores(model, pair)
  }
}

struct Configuration {
  let name: String
  let profiles: [(model: String, weight: Double)]
}
var configurations: [Configuration] = [Configuration(name: "local-only", profiles: [])]
for model in allModels {
  configurations.append(Configuration(name: model, profiles: [(model, 1.0)]))
}
// RB_FUSIONS = comma-separated fusions, each "modelA+modelB*0.5+modelC" (weight defaults to 1).
let defaultFusions = [
  "bge-m3+qwen3-emb-0.6b", "nomic-v1.5+bge-m3", "nomic-v1.5+qwen3-emb-0.6b",
  "nomic-v1.5+bge-m3+qwen3-emb-0.6b", "nomic-v1.5*0.1+bge-m3+qwen3-emb-0.6b",
]
let fusionSpecs =
  environment["RB_FUSIONS"]?.split(separator: ",").map(String.init) ?? defaultFusions
for spec in fusionSpecs {
  let profiles: [(model: String, weight: Double)] = spec.split(separator: "+").map { part in
    let pieces = part.split(separator: "*")
    return (String(pieces[0]), pieces.count > 1 ? Double(pieces[1]) ?? 1 : 1)
  }
  guard profiles.allSatisfy({ allModels.contains($0.model) }) else { continue }
  configurations.append(Configuration(name: spec, profiles: profiles))
}

let settings = [
  Setting(name: "tr->tr", queryLanguage: "tr", documentLanguages: ["tr"]),
  Setting(name: "en->en", queryLanguage: "en", documentLanguages: ["en"]),
  Setting(name: "tr->en", queryLanguage: "tr", documentLanguages: ["en"]),
  Setting(name: "en->tr", queryLanguage: "en", documentLanguages: ["tr"]),
  Setting(name: "tr->mixed", queryLanguage: "tr", documentLanguages: ["tr", "en"]),
  Setting(name: "en->mixed", queryLanguage: "en", documentLanguages: ["tr", "en"]),
]

let container = UUID()
let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
let retriever = HybridMemoryRetriever(
  maximumItems: 10, maximumCharacters: 100_000_000, maximumItemsPerContainer: 10)

var output: [String: Any] = ["n_queries": queryCount, "models": allModels]
var settingResults: [String: Any] = [:]

for setting in settings {
  let started = Date()
  var documentIDs: [UUID] = []
  var candidates: [RetrievalCandidate] = []
  var columnSource: [(language: String, index: Int)] = []
  for language in setting.documentLanguages {
    for (index, text) in dataset.paragraphs[language]!.enumerated() {
      // Deterministic IDs: the retriever breaks exact score ties by UUID string, so random IDs
      // would make runs differ. Index order keeps results reproducible.
      let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", documentIDs.count))!
      documentIDs.append(id)
      columnSource.append((language, index))
      candidates.append(
        RetrievalCandidate(
          id: id, source: .documentChunk, containerID: container, title: "", content: text,
          createdAt: createdAt))
    }
  }
  let ranks = UnsafeMutablePointer<Int>.allocate(capacity: configurations.count * queryCount)
  ranks.initialize(repeating: 0, count: configurations.count * queryCount)
  let documentCount = candidates.count
  // The app's local (lexical + hash + concept) score for every query/candidate pair, so the
  // fusion arithmetic can be replicated and ablated offline.
  let localDump = UnsafeMutablePointer<Float>.allocate(capacity: queryCount * documentCount)
  localDump.initialize(repeating: 0, count: queryCount * documentCount)

  DispatchQueue.concurrentPerform(iterations: queryCount) { q in
    let question = dataset.questions[q]
    let queryText = setting.queryLanguage == "tr" ? question.tr : question.en
    let goldIDs: Set<UUID> = Set(
      columnSource.enumerated().compactMap { column, source in
        source.index == question.gold ? documentIDs[column] : nil
      })
    let local = retriever.prepare(
      query: queryText, candidates: candidates, maximumCount: documentCount
    ).scores
    for (column, id) in documentIDs.enumerated() {
      localDump[q * documentCount + column] = Float(local[id] ?? 0)
    }
    var perModel: [String: [UUID: Double]] = [:]
    for model in allModels {
      var scores: [UUID: Double] = [:]
      scores.reserveCapacity(documentCount)
      for (column, source) in columnSource.enumerated() {
        let matrix = scoreMatrices["\(model).\(setting.queryLanguage)-\(source.language)"]!
        scores[documentIDs[column]] = Double(matrix[q * paragraphCount + source.index])
      }
      perModel[model] = scores
    }
    for (configIndex, models) in configurations.enumerated() {
      let sets = models.profiles.map {
        SemanticScoreSet(profileName: $0.model, weight: $0.weight, scores: perModel[$0.model]!)
      }
      let items = retriever.retrieve(
        query: queryText, candidates: candidates, semanticScoreSets: sets,
        localScoreSnapshot: local
      ).items
      if let position = items.firstIndex(where: { goldIDs.contains($0.id) }) {
        ranks[configIndex * queryCount + q] = position + 1
      }
    }
  }

  var perConfig: [String: [Int]] = [:]
  for (configIndex, models) in configurations.enumerated() {
    perConfig[models.name] = (0..<queryCount).map { ranks[configIndex * queryCount + $0] }
  }
  ranks.deallocate()
  try FileManager.default.createDirectory(
    atPath: "\(work)/local", withIntermediateDirectories: true)
  let safeName = setting.name.replacingOccurrences(of: ">", with: "")
  try Data(bytes: localDump, count: queryCount * documentCount * MemoryLayout<Float>.size)
    .write(to: URL(fileURLWithPath: "\(work)/local/\(safeName).f32"))
  localDump.deallocate()
  settingResults[setting.name] = ["documents": documentCount, "ranks": perConfig]
  let seconds = Int(Date().timeIntervalSince(started))
  print(
    "\(setting.name): \(documentCount) docs, \(queryCount) queries, "
      + "\(configurations.count) configs in \(seconds)s")
}
output["settings"] = settingResults
let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(work)/\(outputName).json"))
print("wrote \(work)/\(outputName).json")
