import CryptoKit
import Foundation
import SwiftData

struct MosaicTranscriptMessage: Identifiable, Hashable, Sendable {
  let id: UUID
  let conversationID: UUID
  let role: MessageRole
  let content: String
  let status: MessageStatus
  let providerConfigurationID: UUID?
  let providerKind: ProviderKind?
  let providerDisplayName: String?
  let providerHost: String?
  let providerMessageID: String?
  let modelIdentifier: String?
  let inputTokenCount: Int?
  let outputTokenCount: Int?
  let errorDescription: String?
  let contextReceiptData: Data?
  let createdAt: Date
  let updatedAt: Date

  init(_ record: MessageRecord) {
    id = record.id
    conversationID = record.conversationID
    role = record.role
    content = record.content
    status = record.status
    providerConfigurationID = record.providerConfigurationID
    providerKind = record.providerKindSnapshot
    providerDisplayName = record.providerDisplayName
    providerHost = record.providerHost
    providerMessageID = record.providerMessageID
    modelIdentifier = record.modelIdentifier
    inputTokenCount = record.inputTokenCount
    outputTokenCount = record.outputTokenCount
    errorDescription = record.errorDescription
    contextReceiptData = record.contextReceiptData
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }
}

/// A stable keyset boundary for fetching records strictly older than one already displayed row.
/// Unlike offsets, concurrent inserts or deletions cannot shift this boundary and duplicate or
/// skip an existing row.
struct MosaicTranscriptCursor: Hashable, Sendable {
  let createdAt: Date
  let id: UUID
}

/// One immutable page from the live transcript. `messages` is chronological within the page;
/// `nextCursor` continues strictly before its oldest row.
struct MosaicTranscriptPage: Hashable, Sendable {
  let messages: [MosaicTranscriptMessage]
  let nextCursor: MosaicTranscriptCursor?
  let pageSize: Int
  let hasMore: Bool

  static let empty = MosaicTranscriptPage(
    messages: [],
    nextCursor: nil,
    pageSize: 0,
    hasMore: false
  )
}

/// A stable keyset boundary for curated memories. `createdAt` is the immutable recency signal;
/// edits may change `updatedAt` without moving an already-scanned row across this boundary.
struct MosaicCuratedMemoryCursor: Hashable, Sendable {
  let createdAt: Date
  let id: UUID
}

/// One immutable page of eligible curated memories, newest creation first.
struct MosaicCuratedMemoryPage: Hashable, Sendable {
  let memories: [MemorySnapshot]
  let nextCursor: MosaicCuratedMemoryCursor?
  let hasMore: Bool
}

private enum CuratedMemorySourceFingerprint {
  static func make(title: String, content: String) -> String {
    EmbeddingVectorCodec.fingerprint(
      for: "\(title.utf8.count):\(title)\(content.utf8.count):\(content)"
    )
  }
}

enum MosaicActiveCompactionSource: Hashable, Sendable {
  case none
  case normalized
  case legacy
}

struct MosaicConversationCanonicalState: Hashable, Sendable {
  let messages: [AIChatMessage]
  let recallCandidates: [RetrievalCandidate]
  let activeCompactionSnapshot: ConversationCompactionSnapshot?
  let normalizedCompactionArtifactID: UUID?
  let activeCompactionSource: MosaicActiveCompactionSource
}

/// Immutable project audience used to bind one provider request to the exact project state that
/// supplied its instructions and memory. The binding identity and both update timestamps make a
/// move-away-and-back or an instruction edit observable before any text leaves the device.
struct MosaicConversationProjectContextSnapshot: Hashable, Sendable {
  let conversationID: UUID
  let bindingID: UUID?
  let bindingUpdatedAt: Date?
  let projectUpdatedAt: Date?
  let isProjectArchived: Bool?
  let receipt: ProjectContextReceipt?

  var audienceScope: ConversationProjectScope {
    ConversationProjectScope(
      conversationID: conversationID,
      projectID: receipt?.projectID,
      bindingID: bindingID,
      bindingUpdatedAt: bindingUpdatedAt
    )
  }
}

enum MosaicConversationReadError: Error, Equatable, LocalizedError, Sendable {
  case conversationNotFound(UUID)
  case messageNotFound(UUID)
  case canonicalHistoryLimitExceeded(maximumRecords: Int, maximumUTF8Bytes: Int)
  case curatedMemoryScanLimitExceeded(maximumRecords: Int)

  var errorDescription: String? {
    switch self {
    case .conversationNotFound:
      "This conversation is no longer available."
    case .messageNotFound:
      "The selected message is no longer available."
    case .canonicalHistoryLimitExceeded(let maximumRecords, let maximumUTF8Bytes):
      "This chat exceeds Turing AI’s safe preparation limit of \(maximumRecords.formatted()) records or \(ByteCountFormatter.string(fromByteCount: Int64(maximumUTF8Bytes), countStyle: .binary)) of message text. Start a new chat to continue without risking an out-of-memory failure."
    case .curatedMemoryScanLimitExceeded(let maximumRecords):
      "Turing AI inspected \(maximumRecords.formatted()) saved-memory records without finding enough usable facts. Remove blank memory entries before trying again."
    }
  }
}

/// Performs transcript, curated-memory, and canonical-history reads on a private SwiftData
/// executor. Persistent model instances never cross the actor boundary.
@ModelActor
actor MosaicConversationReadRepository {
  private static let maximumTranscriptPageSize = 16
  private static let maximumMemoryFetchPageSize = 4
  private static let memoryLimit = 20
  private static let memoryCharacterLimit = 12_000
  private static let maximumMemorySnapshotUTF8Bytes = 64 * 1_024
  private static let maximumMemoryRecordsScanned = 4_096
  private static let maximumCanonicalSourceRecords = 20_000
  private static let maximumCanonicalUTF8Bytes = 16 * 1_024 * 1_024
  private static let canonicalFetchPageSize = 4
  private static let maximumCompactionCoverageDepth = 1_024

  /// Uses a fresh context on every call so commits from another window or process are not hidden
  /// by model-object identity caching in the repository's long-lived executor.
  func projectContextSnapshot(
    conversationID: UUID
  ) throws -> MosaicConversationProjectContextSnapshot {
    try Task.checkCancellation()
    let validationContext = ModelContext(modelContainer)
    let conversationID = conversationID
    var conversationDescriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == conversationID }
    )
    conversationDescriptor.fetchLimit = 1
    conversationDescriptor.includePendingChanges = false
    guard try validationContext.fetch(conversationDescriptor).first != nil else {
      throw MosaicConversationReadError.conversationNotFound(conversationID)
    }

    let bindingKey = ProjectResourceBindingRecord.makeBindingKey(
      resourceKind: .conversation,
      resourceID: conversationID
    )
    var bindingDescriptor = FetchDescriptor<ProjectResourceBindingRecord>(
      predicate: #Predicate { $0.bindingKey == bindingKey }
    )
    bindingDescriptor.fetchLimit = 1
    bindingDescriptor.includePendingChanges = false
    guard let binding = try validationContext.fetch(bindingDescriptor).first else {
      return MosaicConversationProjectContextSnapshot(
        conversationID: conversationID,
        bindingID: nil,
        bindingUpdatedAt: nil,
        projectUpdatedAt: nil,
        isProjectArchived: nil,
        receipt: nil
      )
    }

    let projectID = binding.projectID
    var projectDescriptor = FetchDescriptor<ProjectRecord>(
      predicate: #Predicate { $0.id == projectID }
    )
    projectDescriptor.fetchLimit = 1
    projectDescriptor.includePendingChanges = false
    guard let project = try validationContext.fetch(projectDescriptor).first else {
      throw ProjectBindingError.projectUnavailable(projectID)
    }
    return MosaicConversationProjectContextSnapshot(
      conversationID: conversationID,
      bindingID: binding.id,
      bindingUpdatedAt: binding.updatedAt,
      projectUpdatedAt: project.updatedAt,
      isProjectArchived: project.isArchived,
      receipt: ProjectContextReceipt(
        projectID: project.id,
        name: project.name,
        instructions: project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
  }

  /// Revalidates the exact curated-memory rows selected earlier. This is intentionally separate
  /// from rebuilding the top-N set: a newer unrelated memory may change ranking, but it must not
  /// invalidate an already prepared request; edits, deletion, disabling, or audience moves do.
  func curatedMemoryContextIsCurrent(
    _ context: MemoryContext,
    conversationID: UUID,
    projectID: UUID?
  ) throws -> Bool {
    try Task.checkCancellation()
    let expectedByID = Dictionary(
      context.includedMemories.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard expectedByID.count == context.includedMemories.count else { return false }
    guard !expectedByID.isEmpty else { return true }

    let validationContext = ModelContext(modelContainer)
    let ids = Array(expectedByID.keys)
    var recordsByID: [UUID: MemoryRecord] = [:]
    for page in ids.chunked(maximumCount: 128) {
      try Task.checkCancellation()
      let pageIDs = page
      let descriptor = FetchDescriptor<MemoryRecord>(
        predicate: #Predicate { pageIDs.contains($0.id) }
      )
      for record in try validationContext.fetch(descriptor) {
        guard recordsByID.updateValue(record, forKey: record.id) == nil else { return false }
      }
    }
    guard recordsByID.count == expectedByID.count else { return false }

    let projectIDsByMemory = try ProjectBindingStore.projectIDs(
      resourceKind: .memory,
      resourceIDs: ids,
      in: validationContext
    )
    for (id, expected) in expectedByID {
      guard let record = recordsByID[id],
        record.isEnabled,
        record.isUserApproved,
        let sourceFingerprint = expected.sourceFingerprint,
        CuratedMemorySourceFingerprint.make(title: record.title, content: record.content)
          == sourceFingerprint,
        record.scope == expected.scope
      else {
        return false
      }
      switch record.scope {
      case .global:
        guard record.conversationID == nil, projectIDsByMemory[id] == nil else { return false }
      case .project:
        guard let projectID, record.conversationID == nil,
          projectIDsByMemory[id] == projectID
        else {
          return false
        }
      case .conversation:
        guard record.conversationID == conversationID, projectIDsByMemory[id] == nil else {
          return false
        }
      }
    }
    return true
  }

  func transcriptPage(
    conversationID: UUID,
    before cursor: MosaicTranscriptCursor? = nil,
    pageSize requestedPageSize: Int = 64
  ) throws -> MosaicTranscriptPage {
    try Task.checkCancellation()
    let conversationID = conversationID
    let pageSize = min(Self.maximumTranscriptPageSize, max(1, requestedPageSize))

    let descriptor: FetchDescriptor<MessageRecord>
    if let cursor {
      let cursorDate = cursor.createdAt
      let cursorID = cursor.id
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.conversationID == conversationID
            && ($0.createdAt < cursorDate
              || ($0.createdAt == cursorDate && $0.id < cursorID))
        },
        sortBy: Self.reverseMessageSort
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate { $0.conversationID == conversationID },
        sortBy: Self.reverseMessageSort
      )
    }

    var pageDescriptor = descriptor
    pageDescriptor.fetchLimit = pageSize + 1
    pageDescriptor.includePendingChanges = false
    let records = try modelContext.fetch(pageDescriptor)
    try Task.checkCancellation()
    let includedRecords = Array(records.prefix(pageSize))
    let messages = includedRecords.reversed().map(MosaicTranscriptMessage.init)
    let nextCursor = includedRecords.last.map {
      MosaicTranscriptCursor(createdAt: $0.createdAt, id: $0.id)
    }
    return MosaicTranscriptPage(
      messages: messages,
      nextCursor: nextCursor,
      pageSize: pageSize,
      hasMore: records.count > pageSize
    )
  }

  /// Pages past blank curated rows until it has the first twenty usable memories. This keeps each
  /// SwiftData fetch bounded without allowing newer blank records to hide older valid facts.
  /// Creation-time keysets also prevent concurrent edits from shifting rows between pages.
  func curatedMemoryContext(
    conversationID: UUID?,
    pageSize requestedPageSize: Int = 64,
    builder requestedBuilder: MemoryContextBuilder? = nil
  ) throws -> MemoryContext {
    let projectID = try conversationID.flatMap {
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: $0,
        in: modelContext
      )
    }
    let pageSize = min(Self.maximumMemoryFetchPageSize, max(1, requestedPageSize))
    let memoryLimit = min(Self.memoryLimit, requestedBuilder?.maximumMemories ?? Self.memoryLimit)
    let memoryCharacterLimit = min(
      Self.memoryCharacterLimit,
      requestedBuilder?.maximumContentCharacters ?? Self.memoryCharacterLimit
    )
    let memoryTitleLimit = min(160, requestedBuilder?.maximumTitleCharacters ?? 160)
    let memoryUTF8Limit = min(
      Self.maximumMemorySnapshotUTF8Bytes,
      requestedBuilder?.maximumContextUTF8Bytes ?? Self.maximumMemorySnapshotUTF8Bytes
    )
    guard memoryLimit > 0,
      memoryCharacterLimit > 0,
      memoryTitleLimit > 0,
      memoryUTF8Limit > 0
    else {
      return .empty
    }
    let memoryBuilder = MemoryContextBuilder(
      maximumMemories: memoryLimit,
      maximumContentCharacters: memoryCharacterLimit,
      maximumTitleCharacters: memoryTitleLimit,
      maximumContextUTF8Bytes: memoryUTF8Limit
    )
    var recordsScanned = 0
    var retainedUTF8Bytes = 0
    var snapshots: [MemorySnapshot] = []
    snapshots.reserveCapacity(memoryLimit)
    var cursor: MosaicCuratedMemoryCursor?

    while snapshots.count < memoryLimit,
      retainedUTF8Bytes < memoryUTF8Limit
    {
      try Task.checkCancellation()
      guard recordsScanned < Self.maximumMemoryRecordsScanned else {
        throw MosaicConversationReadError.curatedMemoryScanLimitExceeded(
          maximumRecords: Self.maximumMemoryRecordsScanned
        )
      }
      let memoryFetchLimit = min(
        pageSize,
        Self.maximumMemoryRecordsScanned - recordsScanned
      )
      let page = try curatedMemoryPage(
        conversationID: conversationID,
        projectID: projectID,
        before: cursor,
        pageSize: memoryFetchLimit
      )
      guard !page.memories.isEmpty else { break }

      for (index, snapshot) in page.memories.enumerated() {
        if index.isMultiple(of: 32) { try Task.checkCancellation() }
        let remainingUTF8Bytes = memoryUTF8Limit - retainedUTF8Bytes
        guard
          let snapshot = memoryBuilder.boundedSnapshot(
            snapshot,
            maximumUTF8Bytes: remainingUTF8Bytes
          )
        else { continue }
        retainedUTF8Bytes += snapshot.title.utf8.count + snapshot.content.utf8.count
        snapshots.append(snapshot)
        if snapshots.count == memoryLimit { break }
      }

      recordsScanned += page.memories.count
      cursor = page.nextCursor
      if retainedUTF8Bytes >= memoryUTF8Limit { break }
      if snapshots.count < memoryLimit,
        recordsScanned >= Self.maximumMemoryRecordsScanned
      {
        throw MosaicConversationReadError.curatedMemoryScanLimitExceeded(
          maximumRecords: Self.maximumMemoryRecordsScanned
        )
      }
      if !page.hasMore { break }
    }

    return memoryBuilder.build(
      from: snapshots,
      for: conversationID,
      projectID: projectID
    )
  }

  /// Fetches one bounded page with the same keyset semantics as full context preparation.
  func curatedMemoryPage(
    conversationID: UUID?,
    before cursor: MosaicCuratedMemoryCursor? = nil,
    pageSize requestedPageSize: Int = 64
  ) throws -> MosaicCuratedMemoryPage {
    let projectID = try conversationID.flatMap {
      try ProjectBindingStore.projectID(
        resourceKind: .conversation,
        resourceID: $0,
        in: modelContext
      )
    }
    return try curatedMemoryPage(
      conversationID: conversationID,
      projectID: projectID,
      before: cursor,
      pageSize: requestedPageSize
    )
  }

  private func curatedMemoryPage(
    conversationID: UUID?,
    projectID: UUID?,
    before cursor: MosaicCuratedMemoryCursor?,
    pageSize requestedPageSize: Int
  ) throws -> MosaicCuratedMemoryPage {
    try Task.checkCancellation()
    let pageSize = min(Self.maximumMemoryFetchPageSize, max(1, requestedPageSize))
    var nonProjectDescriptor = memoryDescriptor(
      conversationID: conversationID,
      includesProjectScope: false,
      before: cursor
    )
    nonProjectDescriptor.fetchLimit = pageSize + 1
    nonProjectDescriptor.includePendingChanges = false
    var records = try modelContext.fetch(nonProjectDescriptor)

    // Project membership lives in a sidecar table, so select the exact audience first. Scanning
    // every project's MemoryRecord rows and filtering afterward lets a large unrelated project
    // hide valid older facts behind the global safety cap.
    if let projectID {
      let memoryKind = ProjectResourceKind.memory.rawValue
      var bindingDescriptor = FetchDescriptor<ProjectResourceBindingRecord>(
        predicate: #Predicate {
          $0.projectID == projectID && $0.resourceKindRawValue == memoryKind
        },
        sortBy: [SortDescriptor(\ProjectResourceBindingRecord.id)]
      )
      bindingDescriptor.fetchLimit = Self.maximumMemoryRecordsScanned + 1
      bindingDescriptor.includePendingChanges = false
      let bindings = try modelContext.fetch(bindingDescriptor)
      guard bindings.count <= Self.maximumMemoryRecordsScanned else {
        throw MosaicConversationReadError.curatedMemoryScanLimitExceeded(
          maximumRecords: Self.maximumMemoryRecordsScanned
        )
      }
      for idPage in bindings.map(\.resourceID).chunked(maximumCount: 128) {
        try Task.checkCancellation()
        let ids = idPage
        let projectScope = MemoryScope.project.rawValue
        let projectDescriptor: FetchDescriptor<MemoryRecord>
        if let cursor {
          let cursorDate = cursor.createdAt
          let cursorID = cursor.id
          projectDescriptor = FetchDescriptor(
            predicate: #Predicate {
              ids.contains($0.id) && $0.isEnabled && $0.isUserApproved
                && $0.scopeRawValue == projectScope
                && ($0.createdAt < cursorDate
                  || ($0.createdAt == cursorDate && $0.id < cursorID))
            }
          )
        } else {
          projectDescriptor = FetchDescriptor(
            predicate: #Predicate {
              ids.contains($0.id) && $0.isEnabled && $0.isUserApproved
                && $0.scopeRawValue == projectScope
            }
          )
        }
        records.append(contentsOf: try modelContext.fetch(projectDescriptor))
      }
    }
    records.sort {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id > $1.id
    }
    try Task.checkCancellation()
    let includedRecords = Array(records.prefix(pageSize))
    return MosaicCuratedMemoryPage(
      memories: try includedRecords.map { record in
        let resolvedProjectID =
          record.scope == .project
          ? try ProjectBindingStore.projectID(
            resourceKind: .memory,
            resourceID: record.id,
            in: modelContext
          ) : nil
        return MemorySnapshot(
          id: record.id,
          title: record.title,
          content: record.content,
          scope: record.scope,
          projectID: resolvedProjectID,
          conversationID: record.conversationID,
          isEnabled: record.isEnabled,
          isUserApproved: record.isUserApproved,
          updatedAt: record.updatedAt,
          sourceFingerprint: CuratedMemorySourceFingerprint.make(
            title: record.title,
            content: record.content
          )
        )
      },
      nextCursor: includedRecords.last.map {
        MosaicCuratedMemoryCursor(createdAt: $0.createdAt, id: $0.id)
      },
      hasMore: records.count > pageSize
    )
  }

  /// Builds the complete provider-facing history and recall candidates on the model actor. Only
  /// immutable domain values leave the actor; no unbounded SwiftData model array does.
  func canonicalState(conversationID: UUID) throws -> MosaicConversationCanonicalState {
    try Task.checkCancellation()
    let conversationID = conversationID
    var conversationDescriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == conversationID }
    )
    conversationDescriptor.fetchLimit = 1
    conversationDescriptor.includePendingChanges = false
    guard let conversation = try modelContext.fetch(conversationDescriptor).first else {
      throw MosaicConversationReadError.conversationNotFound(conversationID)
    }
    let title = conversation.title
    let legacySnapshotData = conversation.compactionSnapshotData

    let rows = try boundedCanonicalRows(conversationID: conversationID)

    let messages = rows.map(\.chatMessage)
    let recallCandidates = rows.compactMap { row -> RetrievalCandidate? in
      guard row.role == .user,
        !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      return RetrievalCandidate(
        id: row.id,
        source: .conversationMessage,
        containerID: conversationID,
        title: title,
        content: row.content,
        createdAt: row.createdAt
      )
    }

    let normalized = try activeNormalizedCompactionSnapshot(
      conversationID: conversationID,
      canonicalMessages: messages
    )
    let selected = try selectActiveCompactionSnapshot(
      normalized: normalized.snapshot,
      legacySnapshotData: legacySnapshotData,
      conversationID: conversationID,
      canonicalMessages: messages
    )
    return MosaicConversationCanonicalState(
      messages: messages,
      recallCandidates: recallCandidates,
      activeCompactionSnapshot: selected.snapshot,
      normalizedCompactionArtifactID: normalized.artifactID,
      activeCompactionSource: selected.source
    )
  }

  /// Returns only completed provider-facing messages that canonically precede one persisted
  /// attempt. Retry preparation therefore stays exact without loading the transcript on the UI
  /// actor or accidentally including turns written after the failed attempt.
  func completedMessages(
    conversationID: UUID,
    before boundaryMessageID: UUID
  ) throws -> [AIChatMessage] {
    try Task.checkCancellation()
    let conversationID = conversationID
    let boundaryMessageID = boundaryMessageID
    var boundaryDescriptor = FetchDescriptor<MessageRecord>(
      predicate: #Predicate {
        $0.conversationID == conversationID && $0.id == boundaryMessageID
      }
    )
    boundaryDescriptor.fetchLimit = 1
    boundaryDescriptor.includePendingChanges = false
    guard let boundaryRecord = try modelContext.fetch(boundaryDescriptor).first else {
      throw MosaicConversationReadError.messageNotFound(boundaryMessageID)
    }
    let boundary = MosaicCanonicalMessageRow(boundaryRecord)

    return try boundedCanonicalRows(
      conversationID: conversationID,
      before: boundary
    ).map(\.chatMessage)
  }

  /// Reads canonical rows in small pages and fails before either the record or UTF-8 budget can
  /// grow without bound. The caps are deliberately much larger than a normal provider context,
  /// but small enough to avoid an iOS process being killed by a pathological local library.
  private func boundedCanonicalRows(
    conversationID: UUID,
    before boundary: MosaicCanonicalMessageRow? = nil
  ) throws -> [MosaicCanonicalMessageRow] {
    let conversationID = conversationID
    var sourceRecordCount = 0
    var canonicalUTF8Bytes = 0
    var rows: [MosaicCanonicalMessageRow] = []
    var cursor: MosaicTranscriptCursor?

    while true {
      try Task.checkCancellation()
      let remainingBeforeOverflow = Self.maximumCanonicalSourceRecords - sourceRecordCount
      let fetchLimit = min(Self.canonicalFetchPageSize, max(1, remainingBeforeOverflow + 1))
      let descriptor: FetchDescriptor<MessageRecord>
      if let boundary, let cursor {
        let boundaryDate = boundary.createdAt
        let cursorDate = cursor.createdAt
        let cursorID = cursor.id
        descriptor = FetchDescriptor(
          predicate: #Predicate {
            $0.conversationID == conversationID && $0.createdAt <= boundaryDate
              && ($0.createdAt > cursorDate
                || ($0.createdAt == cursorDate && $0.id > cursorID))
          },
          sortBy: Self.forwardMessageSort
        )
      } else if let boundary {
        let boundaryDate = boundary.createdAt
        descriptor = FetchDescriptor(
          predicate: #Predicate {
            $0.conversationID == conversationID && $0.createdAt <= boundaryDate
          },
          sortBy: Self.forwardMessageSort
        )
      } else if let cursor {
        let cursorDate = cursor.createdAt
        let cursorID = cursor.id
        descriptor = FetchDescriptor(
          predicate: #Predicate {
            $0.conversationID == conversationID
              && ($0.createdAt > cursorDate
                || ($0.createdAt == cursorDate && $0.id > cursorID))
          },
          sortBy: Self.forwardMessageSort
        )
      } else {
        descriptor = FetchDescriptor(
          predicate: #Predicate { $0.conversationID == conversationID },
          sortBy: Self.forwardMessageSort
        )
      }
      var pageDescriptor = descriptor
      pageDescriptor.fetchLimit = fetchLimit
      pageDescriptor.includePendingChanges = false
      let page = try modelContext.fetch(pageDescriptor)
      guard !page.isEmpty else { break }

      for record in page {
        sourceRecordCount += 1
        guard sourceRecordCount <= Self.maximumCanonicalSourceRecords else {
          throw MosaicConversationReadError.canonicalHistoryLimitExceeded(
            maximumRecords: Self.maximumCanonicalSourceRecords,
            maximumUTF8Bytes: Self.maximumCanonicalUTF8Bytes
          )
        }
        guard record.status == .complete,
          record.role == .user || record.role == .assistant
        else {
          continue
        }
        let row = MosaicCanonicalMessageRow(record)
        if let boundary,
          !MosaicCanonicalMessageRow.areInCanonicalOrder(row, boundary)
        {
          continue
        }
        let (nextByteCount, overflow) = canonicalUTF8Bytes.addingReportingOverflow(
          record.content.utf8.count
        )
        guard !overflow, nextByteCount <= Self.maximumCanonicalUTF8Bytes else {
          throw MosaicConversationReadError.canonicalHistoryLimitExceeded(
            maximumRecords: Self.maximumCanonicalSourceRecords,
            maximumUTF8Bytes: Self.maximumCanonicalUTF8Bytes
          )
        }
        canonicalUTF8Bytes = nextByteCount
        rows.append(row)
      }

      if let last = page.last {
        cursor = MosaicTranscriptCursor(createdAt: last.createdAt, id: last.id)
      }
      if page.count < fetchLimit { break }
    }
    return rows.sorted(by: MosaicCanonicalMessageRow.areInCanonicalOrder)
  }

  private nonisolated static let reverseMessageSort = [
    SortDescriptor(\MessageRecord.createdAt, order: .reverse),
    SortDescriptor(\MessageRecord.id, order: .reverse),
  ]

  private nonisolated static let forwardMessageSort = [
    SortDescriptor(\MessageRecord.createdAt),
    SortDescriptor(\MessageRecord.id),
  ]

  private nonisolated static let memorySort = [
    SortDescriptor(\MemoryRecord.createdAt, order: .reverse),
    SortDescriptor(\MemoryRecord.id, order: .reverse),
  ]

  private func memoryDescriptor(
    conversationID: UUID?,
    includesProjectScope: Bool,
    before cursor: MosaicCuratedMemoryCursor?
  ) -> FetchDescriptor<MemoryRecord> {
    let globalScope = MemoryScope.global.rawValue
    let projectScope = MemoryScope.project.rawValue
    if let conversationID, let cursor {
      let conversationScope = MemoryScope.conversation.rawValue
      let cursorDate = cursor.createdAt
      let cursorID = cursor.id
      return FetchDescriptor(
        predicate: #Predicate {
          $0.isEnabled && $0.isUserApproved
            && ($0.scopeRawValue == globalScope
              || (includesProjectScope && $0.scopeRawValue == projectScope)
              || ($0.scopeRawValue == conversationScope
                && $0.conversationID == conversationID))
            && ($0.createdAt < cursorDate
              || ($0.createdAt == cursorDate && $0.id < cursorID))
        },
        sortBy: Self.memorySort
      )
    }
    if let conversationID {
      let conversationScope = MemoryScope.conversation.rawValue
      return FetchDescriptor(
        predicate: #Predicate {
          $0.isEnabled && $0.isUserApproved
            && ($0.scopeRawValue == globalScope
              || (includesProjectScope && $0.scopeRawValue == projectScope)
              || ($0.scopeRawValue == conversationScope
                && $0.conversationID == conversationID))
        },
        sortBy: Self.memorySort
      )
    }
    if let cursor {
      let cursorDate = cursor.createdAt
      let cursorID = cursor.id
      return FetchDescriptor(
        predicate: #Predicate {
          $0.isEnabled && $0.isUserApproved && $0.scopeRawValue == globalScope
            && ($0.createdAt < cursorDate
              || ($0.createdAt == cursorDate && $0.id < cursorID))
        },
        sortBy: Self.memorySort
      )
    }
    return FetchDescriptor(
      predicate: #Predicate {
        $0.isEnabled && $0.isUserApproved && $0.scopeRawValue == globalScope
      },
      sortBy: Self.memorySort
    )
  }

  private func activeNormalizedCompactionSnapshot(
    conversationID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws -> (artifactID: UUID?, snapshot: ConversationCompactionSnapshot?) {
    var descriptor = FetchDescriptor<ConversationCompactionHeadRecord>(
      predicate: #Predicate { $0.conversationID == conversationID }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    guard let artifactID = try modelContext.fetch(descriptor).first?.activeArtifactID else {
      return (nil, nil)
    }
    return (
      artifactID,
      try projectCompactionSnapshot(
        artifactID: artifactID,
        conversationID: conversationID,
        canonicalMessages: canonicalMessages
      )
    )
  }

  private func selectActiveCompactionSnapshot(
    normalized: ConversationCompactionSnapshot?,
    legacySnapshotData: Data?,
    conversationID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws -> (snapshot: ConversationCompactionSnapshot?, source: MosaicActiveCompactionSource) {
    guard let legacySnapshotData else {
      return (normalized, normalized == nil ? .none : .normalized)
    }

    let legacy: ConversationCompactionSnapshot
    do {
      legacy = try JSONDecoder().decode(
        ConversationCompactionSnapshot.self,
        from: legacySnapshotData
      )
      try NormalizedContextStore.validateLegacyCompactionSnapshot(
        legacy,
        conversationID: conversationID,
        canonicalMessages: canonicalMessages
      )
    } catch {
      if let normalized { return (normalized, .normalized) }
      throw error
    }

    guard let normalized else { return (legacy, .legacy) }
    if normalized == legacy { return (normalized, .normalized) }
    if normalized.coveredMessageIDs.count != legacy.coveredMessageIDs.count {
      return normalized.coveredMessageIDs.count > legacy.coveredMessageIDs.count
        ? (normalized, .normalized) : (legacy, .legacy)
    }
    if normalized.createdAt != legacy.createdAt {
      return normalized.createdAt > legacy.createdAt
        ? (normalized, .normalized) : (legacy, .legacy)
    }
    throw NormalizedContextStoreError.dualReadConflict(
      normalized: normalized.id,
      legacy: legacy.id
    )
  }

  private func projectCompactionSnapshot(
    artifactID: UUID,
    conversationID: UUID,
    canonicalMessages: [AIChatMessage]
  ) throws -> ConversationCompactionSnapshot {
    let artifact = try requiredArtifact(id: artifactID)
    guard artifact.conversationID == conversationID else {
      throw NormalizedContextStoreError.compactionConversationMismatch(artifact.id)
    }
    try validateIntegrity(artifact)
    guard artifact.isSnapshotComplete,
      let contentData = artifact.contentData,
      let sourceFingerprint = artifact.sourceFingerprint,
      let providerConfigurationID = artifact.providerConfigurationID,
      let providerKindRawValue = artifact.providerKindRawValue,
      let providerKind = ProviderKind(rawValue: providerKindRawValue),
      let providerDisplayName = artifact.providerDisplayName,
      let providerEndpoint = artifact.providerEndpoint,
      let modelIdentifier = artifact.modelIdentifier,
      let mode = ConversationCompactionMode(rawValue: artifact.modeRawValue)
    else {
      throw NormalizedContextStoreError.incompleteCompactionArtifact(artifact.id)
    }
    try validateLineage(artifact, mode: mode)

    let content: ConversationCompactionContent
    let warnings: [String]
    do {
      content = try JSONDecoder().decode(ConversationCompactionContent.self, from: contentData)
      warnings = try JSONDecoder().decode([String].self, from: artifact.warningsData)
    } catch {
      throw NormalizedContextStoreError.corruptPayload("compaction artifact payload")
    }
    guard content.schemaVersion == artifact.contentSchemaVersion else {
      throw NormalizedContextStoreError.corruptPayload("compaction content version mismatch")
    }

    let snapshot = ConversationCompactionSnapshot(
      id: artifact.id,
      conversationID: artifact.conversationID,
      previousCompactionID: artifact.lineagePreviousCompactionID,
      mode: mode,
      promptVersion: artifact.promptVersion,
      content: content,
      coveredMessageIDs: try resolveCoverage(
        artifact: artifact,
        canonicalMessages: canonicalMessages
      ),
      sourceFingerprint: sourceFingerprint,
      providerConfigurationID: providerConfigurationID,
      providerKind: providerKind,
      providerDisplayName: providerDisplayName,
      providerEndpoint: providerEndpoint,
      modelIdentifier: modelIdentifier,
      providerMessageID: artifact.providerMessageID,
      inputTokenCount: artifact.inputTokenCount,
      outputTokenCount: artifact.outputTokenCount,
      estimatedSourceTokens: artifact.estimatedSourceTokens,
      estimatedSummaryTokens: artifact.estimatedSummaryTokens,
      chainDepth: artifact.chainDepth,
      warnings: warnings,
      createdAt: artifact.createdAt
    )
    guard snapshot.renderedSummary == artifact.renderedSummary else {
      throw NormalizedContextStoreError.compactionPrefixMismatch(artifact.id)
    }
    try NormalizedContextStore.validateLegacyCompactionSnapshot(
      snapshot,
      conversationID: conversationID,
      canonicalMessages: canonicalMessages
    )
    return snapshot
  }

  private func validateLineage(
    _ artifact: CompactionArtifactRecord,
    mode: ConversationCompactionMode
  ) throws {
    switch mode {
    case .initial:
      guard artifact.chainDepth == 1,
        artifact.lineagePreviousCompactionID == nil,
        artifact.coverageParentArtifactID == nil,
        !artifact.isDetachedCoverageRoot
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid initial compaction lineage")
      }
    case .rebuild:
      guard artifact.chainDepth == 1,
        artifact.lineagePreviousCompactionID != nil
      else {
        throw NormalizedContextStoreError.corruptPayload("invalid rebuild compaction lineage")
      }
    case .extend:
      if let parentID = artifact.coverageParentArtifactID {
        let parent = try requiredArtifact(id: parentID)
        let (expectedDepth, overflow) = parent.chainDepth.addingReportingOverflow(1)
        guard !overflow, artifact.chainDepth == expectedDepth else {
          throw NormalizedContextStoreError.corruptPayload("invalid extended compaction lineage")
        }
      } else {
        guard artifact.isDetachedCoverageRoot, artifact.chainDepth >= 2 else {
          throw NormalizedContextStoreError.corruptPayload("invalid detached compaction lineage")
        }
      }
    }
  }

  private func resolveCoverage(
    artifact: CompactionArtifactRecord,
    canonicalMessages: [AIChatMessage]
  ) throws -> [UUID] {
    var chain: [CompactionArtifactRecord] = []
    var visited: Set<UUID> = []
    var cursor: CompactionArtifactRecord? = artifact
    while let current = cursor {
      try Task.checkCancellation()
      guard visited.insert(current.id).inserted else {
        throw NormalizedContextStoreError.compactionArtifactCycle(current.id)
      }
      guard current.conversationID == artifact.conversationID else {
        throw NormalizedContextStoreError.compactionConversationMismatch(current.id)
      }
      try validateIntegrity(current)
      chain.append(current)
      cursor = try current.coverageParentArtifactID.map(requiredArtifact(id:))
      guard chain.count <= Self.maximumCompactionCoverageDepth else {
        throw NormalizedContextStoreError.compactionArtifactCycle(current.id)
      }
    }

    let canonicalIDs = canonicalMessages.map(\.id)
    var coverage: [UUID] = []
    var seen: Set<UUID> = []
    for current in chain.reversed() {
      let delta: [UUID]
      do {
        delta = try JSONDecoder().decode([UUID].self, from: current.coverageDeltaData)
      } catch {
        throw NormalizedContextStoreError.corruptPayload("compaction coverage delta")
      }
      let start = coverage.count
      guard start <= canonicalIDs.count,
        delta.count <= canonicalIDs.count - start
      else {
        throw NormalizedContextStoreError.compactionCountMismatch(current.id)
      }
      let end = start + delta.count
      guard end == current.coveredMessageCount, end <= canonicalIDs.count else {
        throw NormalizedContextStoreError.compactionCountMismatch(current.id)
      }
      guard Array(canonicalIDs[start..<end]) == delta,
        delta.allSatisfy({ seen.insert($0).inserted })
      else {
        throw NormalizedContextStoreError.compactionPrefixMismatch(current.id)
      }
      coverage.append(contentsOf: delta)
    }
    return coverage
  }

  private func requiredArtifact(id: UUID) throws -> CompactionArtifactRecord {
    var descriptor = FetchDescriptor<CompactionArtifactRecord>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    guard let artifact = try modelContext.fetch(descriptor).first else {
      throw NormalizedContextStoreError.missingCompactionArtifact(id)
    }
    return artifact
  }

  private func validateIntegrity(_ artifact: CompactionArtifactRecord) throws {
    let envelope = MosaicReadCompactionArtifactIntegrityEnvelope(artifact)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let fingerprint = SHA256.hash(data: try encoder.encode(envelope))
      .map { String(format: "%02x", $0) }
      .joined()
    guard fingerprint == artifact.payloadFingerprint else {
      throw NormalizedContextStoreError.corruptPayload(
        "compaction artifact \(artifact.id.uuidString) fingerprint mismatch"
      )
    }
  }
}

private struct MosaicCanonicalMessageRow: Sendable {
  let id: UUID
  let role: MessageRole
  let content: String
  let createdAt: Date

  init(_ record: MessageRecord) {
    id = record.id
    role = record.role
    content = record.content
    createdAt = record.createdAt
  }

  var chatMessage: AIChatMessage {
    AIChatMessage(id: id, role: role, content: content)
  }

  static func areInCanonicalOrder(
    _ lhs: MosaicCanonicalMessageRow,
    _ rhs: MosaicCanonicalMessageRow
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    let lhsRoleRank = lhs.role == .user ? 0 : 1
    let rhsRoleRank = rhs.role == .user ? 0 : 1
    if lhsRoleRank != rhsRoleRank { return lhsRoleRank < rhsRoleRank }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

private struct MosaicReadCompactionArtifactIntegrityEnvelope: Hashable, Codable, Sendable {
  let id: UUID
  let conversationID: UUID
  let lineagePreviousCompactionID: UUID?
  let coverageParentArtifactID: UUID?
  let coverageDeltaData: Data
  let coveredMessageCount: Int
  let modeRawValue: String
  let promptVersion: String
  let contentSchemaVersion: Int
  let contentData: Data?
  let renderedSummary: String
  let sourceFingerprint: String?
  let providerConfigurationID: UUID?
  let providerKindRawValue: String?
  let providerDisplayName: String?
  let providerEndpoint: String?
  let modelIdentifier: String?
  let providerMessageID: String?
  let inputTokenCount: Int?
  let outputTokenCount: Int?
  let estimatedSourceTokens: Int
  let estimatedSummaryTokens: Int
  let chainDepth: Int
  let warningsData: Data
  let isSnapshotComplete: Bool
  let isDetachedCoverageRoot: Bool
  let createdAt: Date

  init(_ artifact: CompactionArtifactRecord) {
    id = artifact.id
    conversationID = artifact.conversationID
    lineagePreviousCompactionID = artifact.lineagePreviousCompactionID
    coverageParentArtifactID = artifact.coverageParentArtifactID
    coverageDeltaData = artifact.coverageDeltaData
    coveredMessageCount = artifact.coveredMessageCount
    modeRawValue = artifact.modeRawValue
    promptVersion = artifact.promptVersion
    contentSchemaVersion = artifact.contentSchemaVersion
    contentData = artifact.contentData
    renderedSummary = artifact.renderedSummary
    sourceFingerprint = artifact.sourceFingerprint
    providerConfigurationID = artifact.providerConfigurationID
    providerKindRawValue = artifact.providerKindRawValue
    providerDisplayName = artifact.providerDisplayName
    providerEndpoint = artifact.providerEndpoint
    modelIdentifier = artifact.modelIdentifier
    providerMessageID = artifact.providerMessageID
    inputTokenCount = artifact.inputTokenCount
    outputTokenCount = artifact.outputTokenCount
    estimatedSourceTokens = artifact.estimatedSourceTokens
    estimatedSummaryTokens = artifact.estimatedSummaryTokens
    chainDepth = artifact.chainDepth
    warningsData = artifact.warningsData
    isSnapshotComplete = artifact.isSnapshotComplete
    isDetachedCoverageRoot = artifact.isDetachedCoverageRoot
    createdAt = artifact.createdAt
  }
}
