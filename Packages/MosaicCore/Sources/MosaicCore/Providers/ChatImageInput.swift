import Foundation

public struct ChatImageInput: Hashable, Sendable {
  public let mimeType: String
  public let data: Data
  public init(mimeType: String, data: Data) {
    self.mimeType = mimeType
    self.data = data
  }
  var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}
