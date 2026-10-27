import Foundation
import MosaicCore

// Line-oriented harness around the app's real memory extraction request builder and validator.
//
// stdin: one JSON object per line
//   {"op":"request"|"validate", "conversationID":UUID, "throughUserMessageID":UUID, "assistantMessageID":UUID,
//    "message":{"id":UUID,"role":"user","content":"...","createdAt":ISO8601},
//    "existingTopics":[AutomaticMemoryTopicSnapshot...], "response":"<model output, validate only>"}
// stdout: one JSON object per line
//   request  -> {"ok":true,"system":"...","user":"...","maxOutputTokens":N,"sourceFingerprint":"..."}
//   validate -> {"ok":true,"operations":[...]} or {"ok":false,"error":"..."}
//
// The preparation mirrors AutomaticMemoryStore.prepare: exactly one user message, the visible topic snapshots,
// no project. The request uses the conservative default context policy (32k window), which is what the app
// uses when no provider-specific limits are known.

struct Input: Decodable {
  let op: String
  let conversationID: UUID
  let throughUserMessageID: UUID
  let assistantMessageID: UUID
  let message: AutomaticMemorySourceMessage
  let existingTopics: [AutomaticMemoryTopicSnapshot]
  let response: String?
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func emit(_ object: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func describe(_ error: Error) -> String {
  if let e = error as? AutomaticMemoryExtractionError {
    switch e {
    case .invalidPreparation: return "invalidPreparation"
    case .incompleteResponse: return "incompleteResponse"
    case .emptyResponse: return "emptyResponse"
    case .responseTooLarge: return "responseTooLarge"
    case .invalidOutput: return "invalidOutput"
    case .invalidEvidence(let id): return "invalidEvidence(\(id.uuidString.lowercased()))"
    case .invalidTarget(let id): return "invalidTarget(\(id?.uuidString.lowercased() ?? "nil"))"
    }
  }
  return String(describing: error)
}

let extractor = AutomaticMemoryExtractor()
while let line = readLine(strippingNewline: true) {
  guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
  do {
    let input = try decoder.decode(Input.self, from: Data(line.utf8))
    let preparation = AutomaticMemoryFormationPreparation(
      jobID: UUID(),
      conversationID: input.conversationID,
      throughUserMessageID: input.throughUserMessageID,
      assistantMessageID: input.assistantMessageID,
      sourceFingerprint: AutomaticMemorySourceFingerprint.make(messages: [input.message]),
      messages: [input.message],
      existingTopics: input.existingTopics
    )
    switch input.op {
    case "request":
      let request = try extractor.request(for: preparation)
      emit([
        "ok": true,
        "system": request.systemPrompt ?? "",
        "user": request.messages.first?.content ?? "",
        "maxOutputTokens": request.maxOutputTokens,
        "sourceFingerprint": preparation.sourceFingerprint,
        "promptVersion": AutomaticMemoryExtractionPrompt.version,
      ])
    case "validate":
      let envelope = try extractor.parseAndValidate(input.response ?? "", preparation: preparation)
      let data = try encoder.encode(envelope.operations)
      let operations = try JSONSerialization.jsonObject(with: data)
      emit(["ok": true, "operations": operations])
    default:
      emit(["ok": false, "error": "unknown op \(input.op)"])
    }
  } catch {
    emit(["ok": false, "error": describe(error)])
  }
}
