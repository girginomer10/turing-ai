import Foundation

struct ConnectionActionReceipt: Codable, Sendable, Hashable, Identifiable {
  enum Outcome: String, Codable, Sendable { case started, succeeded, failed, declined, uncertain }
  let id: UUID
  let service: ConnectorID
  let tool: String
  let arguments: ConnectorJSON
  var outcome: Outcome
  var date: Date
  var summary: String
  var statusTitle: String {
    switch outcome {
    case .started, .uncertain: "Check the service before retrying"
    case .succeeded: "Completed"
    case .failed: "Service reported a failure"
    case .declined: "Declined · Not executed"
    }
  }
  func validate() throws {
    guard tool.utf8.count <= 256, arguments.encoded.utf8.count <= 32_768,
      summary.utf8.count <= 1000, date.timeIntervalSinceReferenceDate.isFinite
    else { throw MosaicPortableBackupError.malformedEnvelope }
  }
}
