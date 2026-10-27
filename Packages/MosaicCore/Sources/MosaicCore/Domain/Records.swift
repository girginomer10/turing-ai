import Foundation
import SwiftData

@Model
public final class ConversationRecord {
  @Attribute(.unique) public var id: UUID
  public var title: String
  public var providerConfigurationID: UUID?
  public var modelIdentifier: String
  public var systemPrompt: String?
  public var draftText: String = ""
  /// App-owned, provider-portable rolling summary. Raw MessageRecord rows remain authoritative.
  public var compactionSnapshotData: Data?
  public var isArchived: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String = "New conversation",
    providerConfigurationID: UUID? = nil,
    modelIdentifier: String = "",
    systemPrompt: String? = nil,
    draftText: String = "",
    compactionSnapshot: ConversationCompactionSnapshot? = nil,
    isArchived: Bool = false,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
    self.systemPrompt = systemPrompt
    self.draftText = draftText
    self.compactionSnapshotData = compactionSnapshot.flatMap { try? JSONEncoder().encode($0) }
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var compactionSnapshot: ConversationCompactionSnapshot? {
    get {
      guard let compactionSnapshotData else { return nil }
      return try? JSONDecoder().decode(
        ConversationCompactionSnapshot.self,
        from: compactionSnapshotData
      )
    }
    set {
      compactionSnapshotData = newValue.flatMap { try? JSONEncoder().encode($0) }
    }
  }
}

@Model
public final class MessageRecord {
  @Attribute(.unique) public var id: UUID
  public var conversationID: UUID
  public var roleRawValue: String
  public var content: String
  public var statusRawValue: String
  public var providerConfigurationID: UUID?
  public var providerKindRawValue: String?
  public var providerDisplayName: String?
  public var providerHost: String?
  public var providerMessageID: String?
  public var modelIdentifier: String?
  public var inputTokenCount: Int?
  public var outputTokenCount: Int?
  public var errorDescription: String?
  public var contextReceiptData: Data?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    conversationID: UUID,
    role: MessageRole,
    content: String,
    status: MessageStatus = .complete,
    providerConfigurationID: UUID? = nil,
    providerKind: ProviderKind? = nil,
    providerDisplayName: String? = nil,
    providerHost: String? = nil,
    providerMessageID: String? = nil,
    modelIdentifier: String? = nil,
    inputTokenCount: Int? = nil,
    outputTokenCount: Int? = nil,
    errorDescription: String? = nil,
    contextReceipt: RequestContextReceipt? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.conversationID = conversationID
    self.roleRawValue = role.rawValue
    self.content = content
    self.statusRawValue = status.rawValue
    self.providerConfigurationID = providerConfigurationID
    self.providerKindRawValue = providerKind?.rawValue
    self.providerDisplayName = providerDisplayName
    self.providerHost = providerHost
    self.providerMessageID = providerMessageID
    self.modelIdentifier = modelIdentifier
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.errorDescription = errorDescription
    self.contextReceiptData = contextReceipt.flatMap { try? JSONEncoder().encode($0) }
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var role: MessageRole {
    get { MessageRole(rawValue: roleRawValue) ?? .assistant }
    set { roleRawValue = newValue.rawValue }
  }

  public var status: MessageStatus {
    get { MessageStatus(rawValue: statusRawValue) ?? .complete }
    set { statusRawValue = newValue.rawValue }
  }

  public var providerKindSnapshot: ProviderKind? {
    get { providerKindRawValue.flatMap(ProviderKind.init(rawValue:)) }
    set { providerKindRawValue = newValue?.rawValue }
  }

  public var contextReceipt: RequestContextReceipt? {
    get {
      guard let contextReceiptData else { return nil }
      return try? JSONDecoder().decode(RequestContextReceipt.self, from: contextReceiptData)
    }
    set {
      contextReceiptData = newValue.flatMap { try? JSONEncoder().encode($0) }
    }
  }
}

@Model
public final class MemoryRecord {
  @Attribute(.unique) public var id: UUID
  public var title: String
  public var content: String
  public var scopeRawValue: String
  public var conversationID: UUID?
  public var isEnabled: Bool
  public var isUserApproved: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    content: String,
    scope: MemoryScope = .global,
    conversationID: UUID? = nil,
    isEnabled: Bool = true,
    isUserApproved: Bool = false,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.scopeRawValue = scope.rawValue
    self.conversationID = conversationID
    self.isEnabled = isEnabled
    self.isUserApproved = isUserApproved
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var scope: MemoryScope {
    get { MemoryScope(rawValue: scopeRawValue) ?? .global }
    set { scopeRawValue = newValue.rawValue }
  }

  public var snapshot: MemorySnapshot {
    MemorySnapshot(
      id: id,
      title: title,
      content: content,
      scope: scope,
      conversationID: conversationID,
      isEnabled: isEnabled,
      isUserApproved: isUserApproved,
      updatedAt: updatedAt
    )
  }
}

@Model
public final class ScheduledTaskRecord {
  @Attribute(.unique) public var id: UUID
  public var title: String
  public var prompt: String
  public var conversationID: UUID?
  public var providerConfigurationID: UUID?
  public var recurrenceRawValue: String
  public var statusRawValue: String
  public var scheduledAt: Date
  public var timeZoneIdentifier: String = TimeZone.current.identifier
  public var nextRunAt: Date?
  public var lastRunAt: Date?
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    prompt: String,
    conversationID: UUID? = nil,
    providerConfigurationID: UUID? = nil,
    recurrence: ScheduleRecurrence = .once,
    status: ScheduledTaskStatus = .active,
    scheduledAt: Date,
    timeZoneIdentifier: String = TimeZone.current.identifier,
    nextRunAt: Date? = nil,
    lastRunAt: Date? = nil,
    lastError: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.prompt = prompt
    self.conversationID = conversationID
    self.providerConfigurationID = providerConfigurationID
    self.recurrenceRawValue = recurrence.rawValue
    self.statusRawValue = status.rawValue
    self.scheduledAt = scheduledAt
    self.timeZoneIdentifier = timeZoneIdentifier
    self.nextRunAt = nextRunAt
    self.lastRunAt = lastRunAt
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var recurrence: ScheduleRecurrence {
    get { ScheduleRecurrence(rawValue: recurrenceRawValue) ?? .once }
    set { recurrenceRawValue = newValue.rawValue }
  }

  public var status: ScheduledTaskStatus {
    get { ScheduledTaskStatus(rawValue: statusRawValue) ?? .active }
    set { statusRawValue = newValue.rawValue }
  }

  public var isEnabled: Bool {
    get { status == .active }
    set { status = newValue ? .active : .paused }
  }
}

@Model
public final class ProviderConfigurationRecord {
  @Attribute(.unique) public var id: UUID
  public var displayName: String
  public var providerRawValue: String
  public var modelIdentifier: String
  public var baseURLString: String?
  /// User-reviewable request limits for the selected model. Optional values preserve
  /// compatibility with provider records created before request budgeting was introduced.
  public var contextWindowTokens: Int?
  public var maximumOutputTokens: Int?
  public var isEnabled: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    provider: ProviderKind,
    modelIdentifier: String,
    baseURL: URL? = nil,
    contextWindowTokens: Int? = nil,
    maximumOutputTokens: Int? = nil,
    isEnabled: Bool = true,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.displayName = displayName
    self.providerRawValue = provider.rawValue
    self.modelIdentifier = modelIdentifier
    self.baseURLString = baseURL?.absoluteString
    self.contextWindowTokens = contextWindowTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var provider: ProviderKind {
    get { ProviderKind(rawValue: providerRawValue) ?? .custom }
    set { providerRawValue = newValue.rawValue }
  }

  public var baseURL: URL? {
    get { baseURLString.flatMap(URL.init(string:)) }
    set { baseURLString = newValue?.absoluteString }
  }

  /// Provider keys are never persisted on this model. This is only a Keychain locator.
  public var credentialReference: ProviderCredentialReference {
    ProviderCredentialReference(configurationID: id)
  }
}

@Model
public final class EmbeddingProfileRecord {
  @Attribute(.unique) public var id: UUID
  public var displayName: String
  public var backendRawValue: String
  public var providerConfigurationID: UUID?
  public var modelIdentifier: String
  public var weight: Double
  public var isEnabled: Bool
  public var indexesConversations: Bool
  public var indexesDocuments: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    backend: EmbeddingBackend = .provider,
    providerConfigurationID: UUID?,
    modelIdentifier: String,
    weight: Double = 1,
    isEnabled: Bool = true,
    indexesConversations: Bool = true,
    indexesDocuments: Bool = true,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.displayName = displayName
    self.backendRawValue = backend.rawValue
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
    self.weight = weight
    self.isEnabled = isEnabled
    self.indexesConversations = indexesConversations
    self.indexesDocuments = indexesDocuments
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var backend: EmbeddingBackend {
    get { EmbeddingBackend(rawValue: backendRawValue) ?? .provider }
    set { backendRawValue = newValue.rawValue }
  }

  public var snapshot: EmbeddingProfileSnapshot {
    EmbeddingProfileSnapshot(
      id: id,
      displayName: displayName,
      backend: backend,
      providerConfigurationID: providerConfigurationID,
      modelIdentifier: modelIdentifier,
      weight: weight,
      isEnabled: isEnabled,
      indexesConversations: indexesConversations,
      indexesDocuments: indexesDocuments
    )
  }
}

@Model
public final class ImportedDocumentRecord {
  @Attribute(.unique) public var id: UUID
  public var title: String
  public var sourceFilename: String
  public var mimeType: String
  public var contentFingerprint: String
  public var characterCount: Int
  public var pageCount: Int?
  public var ocrPageCount: Int = 0
  public var ocrFallbackPageCount: Int = 0
  public var isEnabled: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    sourceFilename: String,
    mimeType: String,
    contentFingerprint: String,
    characterCount: Int,
    pageCount: Int? = nil,
    ocrPageCount: Int = 0,
    ocrFallbackPageCount: Int = 0,
    isEnabled: Bool = true,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.sourceFilename = sourceFilename
    self.mimeType = mimeType
    self.contentFingerprint = contentFingerprint
    self.characterCount = characterCount
    self.pageCount = pageCount
    self.ocrPageCount = ocrPageCount
    self.ocrFallbackPageCount = ocrFallbackPageCount
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

@Model
public final class DocumentChunkRecord {
  @Attribute(.unique) public var id: UUID
  public var documentID: UUID
  public var chunkIndex: Int
  public var content: String
  public var pageNumber: Int?
  public var isOCRDerived: Bool = false
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    documentID: UUID,
    chunkIndex: Int,
    content: String,
    pageNumber: Int? = nil,
    isOCRDerived: Bool = false,
    createdAt: Date = .now
  ) {
    self.id = id
    self.documentID = documentID
    self.chunkIndex = chunkIndex
    self.content = content
    self.pageNumber = pageNumber
    self.isOCRDerived = isOCRDerived
    self.createdAt = createdAt
  }
}

@Model
public final class EmbeddingVectorRecord {
  @Attribute(.unique) public var id: UUID
  @Attribute(.unique) public var cacheKey: String
  public var profileID: UUID
  public var sourceKindRawValue: String
  public var sourceID: UUID
  public var embeddingSpaceIdentifier: String
  public var contentFingerprint: String
  public var dimensions: Int
  public var vectorData: Data
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    sourceKind: RetrievalSourceKind,
    sourceID: UUID,
    embeddingSpaceIdentifier: String,
    contentFingerprint: String,
    dimensions: Int,
    vectorData: Data,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.cacheKey = Self.makeCacheKey(profileID: profileID, sourceID: sourceID)
    self.profileID = profileID
    self.sourceKindRawValue = sourceKind.rawValue
    self.sourceID = sourceID
    self.embeddingSpaceIdentifier = embeddingSpaceIdentifier
    self.contentFingerprint = contentFingerprint
    self.dimensions = dimensions
    self.vectorData = vectorData
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var sourceKind: RetrievalSourceKind {
    get { RetrievalSourceKind(rawValue: sourceKindRawValue) ?? .conversationMessage }
    set { sourceKindRawValue = newValue.rawValue }
  }

  public static func makeCacheKey(profileID: UUID, sourceID: UUID) -> String {
    "\(profileID.uuidString.lowercased())/\(sourceID.uuidString.lowercased())"
  }
}
