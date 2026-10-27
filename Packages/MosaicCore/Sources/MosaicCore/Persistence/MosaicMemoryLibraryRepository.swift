import Foundation
import SwiftData

struct MosaicMemoryLibraryMemoryCursor: Hashable, Sendable {
  let updatedAt: Date
  let createdAt: Date
  let id: UUID
}

struct MosaicMemoryLibraryTopicCursor: Hashable, Sendable {
  let updatedAt: Date
  let createdAt: Date
  let id: UUID
}

struct MosaicMemoryLibraryDocumentCursor: Hashable, Sendable {
  let updatedAt: Date
  let createdAt: Date
  let id: UUID
}

struct MosaicMemoryLibraryConversationCursor: Hashable, Sendable {
  let updatedAt: Date
  let createdAt: Date
  let id: UUID
}

struct MosaicMemoryFormationJobCursor: Hashable, Sendable {
  let updatedAt: Date
  let id: UUID
}

struct MosaicMemoryLibraryItem: Identifiable, Sendable {
  let id: UUID
  let title: String
  let content: String
  let scope: MemoryScope
  let projectID: UUID?
  let projectName: String?
  let conversationID: UUID?
  let conversationTitle: String?
  let isEnabled: Bool
  let isUserApproved: Bool
  let createdAt: Date
  let updatedAt: Date

  fileprivate init(
    _ record: MemoryRecord,
    projectID: UUID?,
    projectName: String?,
    conversationTitle: String?
  ) {
    id = record.id
    title = record.title
    content = record.content
    scope = record.scope
    self.projectID = projectID
    self.projectName = projectName
    conversationID = record.conversationID
    self.conversationTitle = conversationTitle
    isEnabled = record.isEnabled
    isUserApproved = record.isUserApproved
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }
}

struct MosaicMemoryLibraryTopicItem: Identifiable, Sendable {
  let snapshot: AutomaticMemoryTopicSnapshot
  let projectID: UUID?
  let projectName: String?

  var id: UUID { snapshot.id }
  var title: String { snapshot.title }
  var content: String { snapshot.content }
  var kind: MemoryTopicKind { snapshot.kind }
  var scope: MemoryScope { snapshot.scope }
  var conversationID: UUID? { snapshot.conversationID }
  var status: MemoryTopicStatus { snapshot.status }
  var origin: MemoryOrigin { snapshot.origin }
  var confidence: Double { snapshot.confidence }
  var importance: Double { snapshot.importance }
  var stability: MemoryStability { snapshot.stability }
  var isEnabled: Bool { snapshot.isEnabled }
  var evidenceCount: Int { snapshot.evidenceCount }
  var useCount: Int { snapshot.useCount }
  var revision: Int { snapshot.revision }
  var lastConfirmedAt: Date { snapshot.lastConfirmedAt }
  var createdAt: Date { snapshot.createdAt }
  var updatedAt: Date { snapshot.updatedAt }

  fileprivate init(
    _ record: MemoryTopicRecord,
    projectID: UUID? = nil,
    projectName: String? = nil
  ) {
    snapshot = record.snapshot
    self.projectID = projectID
    self.projectName = projectName
  }
}

struct MosaicMemoryLibraryEvidenceItem: Identifiable, Sendable {
  let snapshot: AutomaticMemoryEvidenceSnapshot
  let conversationTitle: String?
  let sourceAvailable: Bool

  var id: UUID { snapshot.id }
}

struct MosaicMemoryLibraryTopicDetail: Sendable {
  let topic: MosaicMemoryLibraryTopicItem
  let evidence: [MosaicMemoryLibraryEvidenceItem]
  let revisions: [AutomaticMemoryRevisionSnapshot]
  let totalEvidenceCount: Int
  let totalRevisionCount: Int
}

struct MosaicMemoryLibraryDocumentItem: Identifiable, Sendable {
  let id: UUID
  let title: String
  let sourceFilename: String
  let mimeType: String
  let contentFingerprint: String
  let characterCount: Int
  let pageCount: Int?
  let ocrPageCount: Int
  let ocrFallbackPageCount: Int
  let isEnabled: Bool
  let projectID: UUID?
  let projectName: String?
  let chunkCount: Int
  let createdAt: Date
  let updatedAt: Date

  fileprivate init(
    _ record: ImportedDocumentRecord,
    chunkCount: Int,
    projectID: UUID?,
    projectName: String?
  ) {
    id = record.id
    title = record.title
    sourceFilename = record.sourceFilename
    mimeType = record.mimeType
    contentFingerprint = record.contentFingerprint
    characterCount = record.characterCount
    pageCount = record.pageCount
    ocrPageCount = record.ocrPageCount
    ocrFallbackPageCount = record.ocrFallbackPageCount
    isEnabled = record.isEnabled
    self.projectID = projectID
    self.projectName = projectName
    self.chunkCount = chunkCount
    createdAt = record.createdAt
    updatedAt = record.updatedAt
  }
}

struct MosaicMemoryLibraryConversationChoice: Identifiable, Sendable {
  let id: UUID
  let title: String
  let updatedAt: Date

  fileprivate init(_ record: ConversationRecord) {
    id = record.id
    title = record.title
    updatedAt = record.updatedAt
  }
}

struct MosaicMemoryLibraryMemoryPage: Sendable {
  let items: [MosaicMemoryLibraryItem]
  let nextCursor: MosaicMemoryLibraryMemoryCursor?

  static let empty = MosaicMemoryLibraryMemoryPage(items: [], nextCursor: nil)
}

struct MosaicMemoryLibraryTopicPage: Sendable {
  let items: [MosaicMemoryLibraryTopicItem]
  let nextCursor: MosaicMemoryLibraryTopicCursor?

  static let empty = MosaicMemoryLibraryTopicPage(items: [], nextCursor: nil)
}

struct MosaicMemoryLibraryDocumentPage: Sendable {
  let items: [MosaicMemoryLibraryDocumentItem]
  let nextCursor: MosaicMemoryLibraryDocumentCursor?

  static let empty = MosaicMemoryLibraryDocumentPage(items: [], nextCursor: nil)
}

struct MosaicMemoryLibraryConversationPage: Sendable {
  let items: [MosaicMemoryLibraryConversationChoice]
  let selectedItem: MosaicMemoryLibraryConversationChoice?
  let nextCursor: MosaicMemoryLibraryConversationCursor?

  static let empty = MosaicMemoryLibraryConversationPage(
    items: [],
    selectedItem: nil,
    nextCursor: nil
  )
}

struct MosaicMemoryLibrarySnapshot: Sendable {
  let topics: MosaicMemoryLibraryTopicPage
  let memories: MosaicMemoryLibraryMemoryPage
  let documents: MosaicMemoryLibraryDocumentPage
  let enabledEmbeddingProfileCount: Int
  let failedFormationJobCount: Int
  let recentFormationAudits: [AutomaticMemoryFormationAuditSnapshot]

  static let empty = MosaicMemoryLibrarySnapshot(
    topics: .empty,
    memories: .empty,
    documents: .empty,
    enabledEmbeddingProfileCount: 0,
    failedFormationJobCount: 0,
    recentFormationAudits: []
  )
}

/// Bounded, immutable reads for the Memory screen. Search may scan the source store, but every
/// fetch is a small keyset page and only the requested result page crosses back to the UI actor.
@ModelActor
actor MosaicMemoryLibraryRepository {
  private static let scanBatchSize = 32
  private static let maximumPageSize = 16

  func snapshot(
    query: String,
    memoryAfter: MosaicMemoryLibraryMemoryCursor?,
    documentAfter: MosaicMemoryLibraryDocumentCursor?,
    topicAfter: MosaicMemoryLibraryTopicCursor? = nil,
    pageSize requestedPageSize: Int
  ) throws -> MosaicMemoryLibrarySnapshot {
    let pageSize = min(Self.maximumPageSize, max(1, requestedPageSize))
    try Task.checkCancellation()
    return MosaicMemoryLibrarySnapshot(
      topics: try topicPage(query: query, after: topicAfter, pageSize: pageSize),
      memories: try memoryPage(
        query: query,
        after: memoryAfter,
        pageSize: pageSize
      ),
      documents: try documentPage(after: documentAfter, pageSize: pageSize),
      enabledEmbeddingProfileCount: try enabledEmbeddingProfileCount(),
      failedFormationJobCount: try failedFormationJobCount(),
      recentFormationAudits: try recentFormationAudits()
    )
  }

  func recentFormationAudits(limit requestedLimit: Int = 20) throws
    -> [AutomaticMemoryFormationAuditSnapshot]
  {
    var descriptor = FetchDescriptor<MemoryFormationAuditRecord>(
      sortBy: [
        SortDescriptor(\MemoryFormationAuditRecord.finishedAt, order: .reverse),
        SortDescriptor(\MemoryFormationAuditRecord.id, order: .reverse),
      ]
    )
    descriptor.fetchLimit = min(50, max(1, requestedLimit))
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).map(\.snapshot)
  }

  func topicDetail(id: UUID) throws -> MosaicMemoryLibraryTopicDetail? {
    let targetID = id
    var topicDescriptor = FetchDescriptor<MemoryTopicRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    topicDescriptor.fetchLimit = 1
    topicDescriptor.includePendingChanges = false
    guard let topic = try modelContext.fetch(topicDescriptor).first else { return nil }

    var evidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { $0.topicID == targetID },
      sortBy: [
        SortDescriptor(\MemoryEvidenceRecord.createdAt, order: .reverse),
        SortDescriptor(\MemoryEvidenceRecord.id),
      ]
    )
    evidenceDescriptor.fetchLimit = 100
    evidenceDescriptor.includePendingChanges = false
    let evidenceRecords = try modelContext.fetch(evidenceDescriptor)
    var totalEvidenceDescriptor = FetchDescriptor<MemoryEvidenceRecord>(
      predicate: #Predicate { $0.topicID == targetID }
    )
    totalEvidenceDescriptor.includePendingChanges = false
    let totalEvidenceCount = try modelContext.fetchCount(totalEvidenceDescriptor)
    let conversationIDs = Array(Set(evidenceRecords.map(\.conversationID)))
    let messageIDs = Array(Set(evidenceRecords.map(\.sourceMessageID)))
    let conversations = try modelContext.fetch(
      FetchDescriptor<ConversationRecord>(
        predicate: #Predicate { conversationIDs.contains($0.id) }
      )
    )
    let titles = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.title) })
    let availableMessageIDs = Set(
      try modelContext.fetch(
        FetchDescriptor<MessageRecord>(predicate: #Predicate { messageIDs.contains($0.id) })
      ).map(\.id)
    )

    var revisionDescriptor = FetchDescriptor<MemoryRevisionRecord>(
      predicate: #Predicate { $0.topicID == targetID },
      sortBy: [
        SortDescriptor(\MemoryRevisionRecord.sequence, order: .reverse),
        SortDescriptor(\MemoryRevisionRecord.id),
      ]
    )
    revisionDescriptor.fetchLimit = 100
    revisionDescriptor.includePendingChanges = false
    var totalRevisionDescriptor = FetchDescriptor<MemoryRevisionRecord>(
      predicate: #Predicate { $0.topicID == targetID }
    )
    totalRevisionDescriptor.includePendingChanges = false
    let topicProjectID = try ProjectBindingStore.projectID(
      resourceKind: .memoryTopic,
      resourceID: topic.id,
      in: modelContext
    )
    let topicProjectName = try topicProjectID.flatMap { try projectName(id: $0) }
    return MosaicMemoryLibraryTopicDetail(
      topic: MosaicMemoryLibraryTopicItem(
        topic,
        projectID: topicProjectID,
        projectName: topicProjectName
      ),
      evidence: evidenceRecords.map {
        MosaicMemoryLibraryEvidenceItem(
          snapshot: $0.snapshot,
          conversationTitle: titles[$0.conversationID],
          sourceAvailable: availableMessageIDs.contains($0.sourceMessageID)
        )
      },
      revisions: try modelContext.fetch(revisionDescriptor).map(\.snapshot),
      totalEvidenceCount: totalEvidenceCount,
      totalRevisionCount: try modelContext.fetchCount(totalRevisionDescriptor)
    )
  }

  func failedFormationJobRetryBoundary() throws -> MosaicMemoryFormationJobCursor? {
    let failed = MemoryFormationJobStatus.failed.rawValue
    var descriptor = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate { $0.statusRawValue == failed },
      sortBy: [
        SortDescriptor(\MemoryFormationJobRecord.updatedAt, order: .reverse),
        SortDescriptor(\MemoryFormationJobRecord.id, order: .reverse),
      ]
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).first.map {
      MosaicMemoryFormationJobCursor(updatedAt: $0.updatedAt, id: $0.id)
    }
  }

  func failedFormationJobs(
    after cursor: MosaicMemoryFormationJobCursor? = nil,
    through boundary: MosaicMemoryFormationJobCursor,
    limit requestedLimit: Int = 16
  ) throws
    -> [AutomaticMemoryPendingJob]
  {
    let failed = MemoryFormationJobStatus.failed.rawValue
    let boundaryDate = boundary.updatedAt
    let boundaryID = boundary.id
    let sort = [
      SortDescriptor(\MemoryFormationJobRecord.updatedAt),
      SortDescriptor(\MemoryFormationJobRecord.id),
    ]
    var descriptor: FetchDescriptor<MemoryFormationJobRecord>
    if let cursor {
      let cursorDate = cursor.updatedAt
      let cursorID = cursor.id
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.statusRawValue == failed
            && ($0.updatedAt > cursorDate
              || ($0.updatedAt == cursorDate && $0.id > cursorID))
            && ($0.updatedAt < boundaryDate
              || ($0.updatedAt == boundaryDate
                && ($0.id < boundaryID || $0.id == boundaryID)))
        },
        sortBy: sort
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.statusRawValue == failed
            && ($0.updatedAt < boundaryDate
              || ($0.updatedAt == boundaryDate
                && ($0.id < boundaryID || $0.id == boundaryID)))
        },
        sortBy: sort
      )
    }
    descriptor.fetchLimit = min(16, max(1, requestedLimit))
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).map {
      AutomaticMemoryPendingJob(
        id: $0.id,
        conversationID: $0.conversationID,
        throughUserMessageID: $0.throughUserMessageID,
        assistantMessageID: $0.assistantMessageID,
        providerConfigurationID: $0.providerConfigurationID,
        modelIdentifier: $0.modelIdentifier,
        status: $0.status,
        attemptCount: $0.attemptCount,
        updatedAt: $0.updatedAt
      )
    }
  }

  func conversationPage(
    query: String,
    after: MosaicMemoryLibraryConversationCursor?,
    pageSize requestedPageSize: Int,
    selectedID: UUID?
  ) throws -> MosaicMemoryLibraryConversationPage {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let pageSize = min(Self.maximumPageSize, max(1, requestedPageSize))
    var matches: [ConversationRecord] = []
    matches.reserveCapacity(pageSize + 1)
    var scanCursor = after

    while matches.count <= pageSize {
      try Task.checkCancellation()
      var descriptor = conversationDescriptor(after: scanCursor)
      descriptor.fetchLimit = Self.scanBatchSize
      descriptor.includePendingChanges = false
      let records = try modelContext.fetch(descriptor)
      guard !records.isEmpty else { break }

      for record in records {
        if query.isEmpty || record.title.localizedStandardContains(query) {
          matches.append(record)
          if matches.count > pageSize { break }
        }
      }
      if matches.count > pageSize { break }
      guard let last = records.last else { break }
      scanCursor = Self.conversationCursor(last)
      if records.count < Self.scanBatchSize { break }
    }

    let visibleRecords = Array(matches.prefix(pageSize))
    let items = visibleRecords.map(MosaicMemoryLibraryConversationChoice.init)
    let selectedItem: MosaicMemoryLibraryConversationChoice?
    if let selectedID, !items.contains(where: { $0.id == selectedID }) {
      selectedItem = try conversation(id: selectedID).map(
        MosaicMemoryLibraryConversationChoice.init
      )
    } else {
      selectedItem = nil
    }
    return MosaicMemoryLibraryConversationPage(
      items: items,
      selectedItem: selectedItem,
      nextCursor: matches.count > pageSize
        ? visibleRecords.last.map(Self.conversationCursor)
        : nil
    )
  }

  private func memoryPage(
    query: String,
    after: MosaicMemoryLibraryMemoryCursor?,
    pageSize: Int
  ) throws -> MosaicMemoryLibraryMemoryPage {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var matches: [MemoryRecord] = []
    matches.reserveCapacity(pageSize + 1)
    var scanCursor = after

    while matches.count <= pageSize {
      try Task.checkCancellation()
      var descriptor = memoryDescriptor(after: scanCursor)
      descriptor.fetchLimit = query.isEmpty ? pageSize + 1 : Self.scanBatchSize
      descriptor.includePendingChanges = false
      let records = try modelContext.fetch(descriptor)
      guard !records.isEmpty else { break }

      for record in records {
        if query.isEmpty
          || record.title.localizedStandardContains(query)
          || record.content.localizedStandardContains(query)
        {
          matches.append(record)
          if matches.count > pageSize { break }
        }
      }
      if query.isEmpty || matches.count > pageSize { break }
      guard let last = records.last else { break }
      scanCursor = Self.memoryCursor(last)
      if records.count < Self.scanBatchSize { break }
    }

    let visibleRecords = Array(matches.prefix(pageSize))
    let projectIDsByMemory = try ProjectBindingStore.projectIDs(
      resourceKind: .memory,
      resourceIDs: visibleRecords.map(\.id),
      in: modelContext
    )
    let projectNames = try projectNamesByID(Array(Set(projectIDsByMemory.values)))
    var items: [MosaicMemoryLibraryItem] = []
    items.reserveCapacity(visibleRecords.count)
    for record in visibleRecords {
      try Task.checkCancellation()
      let conversationTitle: String?
      if record.scope == .conversation, let conversationID = record.conversationID {
        conversationTitle =
          try conversation(id: conversationID)?.title
          ?? "Conversation no longer available"
      } else {
        conversationTitle = nil
      }
      let projectID = projectIDsByMemory[record.id]
      items.append(
        MosaicMemoryLibraryItem(
          record,
          projectID: projectID,
          projectName: projectID.flatMap { projectNames[$0] },
          conversationTitle: conversationTitle
        )
      )
    }
    return MosaicMemoryLibraryMemoryPage(
      items: items,
      nextCursor: matches.count > pageSize
        ? visibleRecords.last.map(Self.memoryCursor)
        : nil
    )
  }

  private func topicPage(
    query: String,
    after: MosaicMemoryLibraryTopicCursor?,
    pageSize: Int
  ) throws -> MosaicMemoryLibraryTopicPage {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var matches: [MemoryTopicRecord] = []
    matches.reserveCapacity(pageSize + 1)
    var scanCursor = after

    while matches.count <= pageSize {
      try Task.checkCancellation()
      var descriptor = topicDescriptor(after: scanCursor)
      descriptor.fetchLimit = query.isEmpty ? pageSize + 1 : Self.scanBatchSize
      descriptor.includePendingChanges = false
      let records = try modelContext.fetch(descriptor)
      guard !records.isEmpty else { break }
      for record in records {
        if query.isEmpty
          || record.title.localizedStandardContains(query)
          || record.content.localizedStandardContains(query)
          || record.kind.displayName.localizedStandardContains(query)
        {
          matches.append(record)
          if matches.count > pageSize { break }
        }
      }
      if query.isEmpty || matches.count > pageSize { break }
      guard let last = records.last else { break }
      scanCursor = Self.topicCursor(last)
      if records.count < Self.scanBatchSize { break }
    }
    let visible = Array(matches.prefix(pageSize))
    let projectIDsByTopic = try ProjectBindingStore.projectIDs(
      resourceKind: .memoryTopic,
      resourceIDs: visible.map(\.id),
      in: modelContext
    )
    let projectNames = try projectNamesByID(Array(Set(projectIDsByTopic.values)))
    return MosaicMemoryLibraryTopicPage(
      items: visible.map { record in
        let projectID = projectIDsByTopic[record.id]
        return MosaicMemoryLibraryTopicItem(
          record,
          projectID: projectID,
          projectName: projectID.flatMap { projectNames[$0] }
        )
      },
      nextCursor: matches.count > pageSize ? visible.last.map(Self.topicCursor) : nil
    )
  }

  private func documentPage(
    after: MosaicMemoryLibraryDocumentCursor?,
    pageSize: Int
  ) throws -> MosaicMemoryLibraryDocumentPage {
    try Task.checkCancellation()
    var descriptor = documentDescriptor(after: after)
    descriptor.fetchLimit = pageSize + 1
    descriptor.includePendingChanges = false
    let records = try modelContext.fetch(descriptor)
    let visibleRecords = Array(records.prefix(pageSize))
    let projectIDsByDocument = try ProjectBindingStore.projectIDs(
      resourceKind: .document,
      resourceIDs: visibleRecords.map(\.id),
      in: modelContext
    )
    let projectNames = try projectNamesByID(Array(Set(projectIDsByDocument.values)))
    var items: [MosaicMemoryLibraryDocumentItem] = []
    items.reserveCapacity(visibleRecords.count)
    for record in visibleRecords {
      try Task.checkCancellation()
      let documentID = record.id
      var chunkDescriptor = FetchDescriptor<DocumentChunkRecord>(
        predicate: #Predicate { $0.documentID == documentID }
      )
      chunkDescriptor.includePendingChanges = false
      let chunkCount = try modelContext.fetchCount(chunkDescriptor)
      let projectID = projectIDsByDocument[record.id]
      items.append(
        MosaicMemoryLibraryDocumentItem(
          record,
          chunkCount: chunkCount,
          projectID: projectID,
          projectName: projectID.flatMap { projectNames[$0] }
        )
      )
    }
    return MosaicMemoryLibraryDocumentPage(
      items: items,
      nextCursor: records.count > pageSize
        ? visibleRecords.last.map(Self.documentCursor)
        : nil
    )
  }

  private func enabledEmbeddingProfileCount() throws -> Int {
    var descriptor = FetchDescriptor<EmbeddingProfileRecord>(
      predicate: #Predicate { $0.isEnabled }
    )
    descriptor.includePendingChanges = false
    return try modelContext.fetchCount(descriptor)
  }

  private func failedFormationJobCount() throws -> Int {
    let failed = MemoryFormationJobStatus.failed.rawValue
    var descriptor = FetchDescriptor<MemoryFormationJobRecord>(
      predicate: #Predicate { $0.statusRawValue == failed }
    )
    descriptor.includePendingChanges = false
    return try modelContext.fetchCount(descriptor)
  }

  private func conversation(id: UUID) throws -> ConversationRecord? {
    let targetID = id
    var descriptor = FetchDescriptor<ConversationRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).first
  }

  private func projectName(id: UUID) throws -> String? {
    let targetID = id
    var descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == targetID })
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = false
    return try modelContext.fetch(descriptor).first?.name
  }

  private func projectNamesByID(_ ids: [UUID]) throws -> [UUID: String] {
    guard !ids.isEmpty else { return [:] }
    let projects = try modelContext.fetch(
      FetchDescriptor<ProjectRecord>(predicate: #Predicate { ids.contains($0.id) })
    )
    return Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
  }

  private func memoryDescriptor(
    after cursor: MosaicMemoryLibraryMemoryCursor?
  ) -> FetchDescriptor<MemoryRecord> {
    guard let cursor else {
      return FetchDescriptor(sortBy: Self.memorySortDescriptors)
    }
    let updatedAt = cursor.updatedAt
    let createdAt = cursor.createdAt
    let id = cursor.id
    return FetchDescriptor(
      predicate: #Predicate {
        $0.updatedAt < updatedAt
          || ($0.updatedAt == updatedAt
            && ($0.createdAt < createdAt || ($0.createdAt == createdAt && $0.id > id)))
      },
      sortBy: Self.memorySortDescriptors
    )
  }

  private func topicDescriptor(
    after cursor: MosaicMemoryLibraryTopicCursor?
  ) -> FetchDescriptor<MemoryTopicRecord> {
    guard let cursor else {
      return FetchDescriptor(sortBy: Self.topicSortDescriptors)
    }
    let updatedAt = cursor.updatedAt
    let createdAt = cursor.createdAt
    let id = cursor.id
    return FetchDescriptor(
      predicate: #Predicate {
        $0.updatedAt < updatedAt
          || ($0.updatedAt == updatedAt
            && ($0.createdAt < createdAt || ($0.createdAt == createdAt && $0.id > id)))
      },
      sortBy: Self.topicSortDescriptors
    )
  }

  private func documentDescriptor(
    after cursor: MosaicMemoryLibraryDocumentCursor?
  ) -> FetchDescriptor<ImportedDocumentRecord> {
    guard let cursor else {
      return FetchDescriptor(sortBy: Self.documentSortDescriptors)
    }
    let updatedAt = cursor.updatedAt
    let createdAt = cursor.createdAt
    let id = cursor.id
    return FetchDescriptor(
      predicate: #Predicate {
        $0.updatedAt < updatedAt
          || ($0.updatedAt == updatedAt
            && ($0.createdAt < createdAt || ($0.createdAt == createdAt && $0.id > id)))
      },
      sortBy: Self.documentSortDescriptors
    )
  }

  private func conversationDescriptor(
    after cursor: MosaicMemoryLibraryConversationCursor?
  ) -> FetchDescriptor<ConversationRecord> {
    guard let cursor else {
      return FetchDescriptor(sortBy: Self.conversationSortDescriptors)
    }
    let updatedAt = cursor.updatedAt
    let createdAt = cursor.createdAt
    let id = cursor.id
    return FetchDescriptor(
      predicate: #Predicate {
        $0.updatedAt < updatedAt
          || ($0.updatedAt == updatedAt
            && ($0.createdAt < createdAt || ($0.createdAt == createdAt && $0.id > id)))
      },
      sortBy: Self.conversationSortDescriptors
    )
  }

  private nonisolated static let memorySortDescriptors = [
    SortDescriptor(\MemoryRecord.updatedAt, order: .reverse),
    SortDescriptor(\MemoryRecord.createdAt, order: .reverse),
    SortDescriptor(\MemoryRecord.id),
  ]

  private nonisolated static let topicSortDescriptors = [
    SortDescriptor(\MemoryTopicRecord.updatedAt, order: .reverse),
    SortDescriptor(\MemoryTopicRecord.createdAt, order: .reverse),
    SortDescriptor(\MemoryTopicRecord.id),
  ]

  private nonisolated static let documentSortDescriptors = [
    SortDescriptor(\ImportedDocumentRecord.updatedAt, order: .reverse),
    SortDescriptor(\ImportedDocumentRecord.createdAt, order: .reverse),
    SortDescriptor(\ImportedDocumentRecord.id),
  ]

  private nonisolated static let conversationSortDescriptors = [
    SortDescriptor(\ConversationRecord.updatedAt, order: .reverse),
    SortDescriptor(\ConversationRecord.createdAt, order: .reverse),
    SortDescriptor(\ConversationRecord.id),
  ]

  private nonisolated static func memoryCursor(
    _ record: MemoryRecord
  ) -> MosaicMemoryLibraryMemoryCursor {
    MosaicMemoryLibraryMemoryCursor(
      updatedAt: record.updatedAt,
      createdAt: record.createdAt,
      id: record.id
    )
  }

  private nonisolated static func topicCursor(
    _ record: MemoryTopicRecord
  ) -> MosaicMemoryLibraryTopicCursor {
    MosaicMemoryLibraryTopicCursor(
      updatedAt: record.updatedAt,
      createdAt: record.createdAt,
      id: record.id
    )
  }

  private nonisolated static func documentCursor(
    _ record: ImportedDocumentRecord
  ) -> MosaicMemoryLibraryDocumentCursor {
    MosaicMemoryLibraryDocumentCursor(
      updatedAt: record.updatedAt,
      createdAt: record.createdAt,
      id: record.id
    )
  }

  private nonisolated static func conversationCursor(
    _ record: ConversationRecord
  ) -> MosaicMemoryLibraryConversationCursor {
    MosaicMemoryLibraryConversationCursor(
      updatedAt: record.updatedAt,
      createdAt: record.createdAt,
      id: record.id
    )
  }
}

struct MosaicDocumentDeletionOutcome: Equatable, Sendable {
  let didDeleteDocument: Bool
  let vectorCleanupSucceeded: Bool
  let deletedVectorCount: Int
}

struct MosaicStagedDocumentDeletion: Sendable {
  let didFindDocument: Bool
  let chunkIDs: Set<UUID>
}

@ModelActor
actor MosaicDocumentSourceDeletionRepository {
  func stageDeletion(documentID: UUID) throws -> MosaicStagedDocumentDeletion {
    modelContext.autosaveEnabled = false
    try Task.checkCancellation()
    let targetID = documentID
    var documentDescriptor = FetchDescriptor<ImportedDocumentRecord>(
      predicate: #Predicate { $0.id == targetID }
    )
    documentDescriptor.fetchLimit = 1
    documentDescriptor.includePendingChanges = false
    guard let document = try modelContext.fetch(documentDescriptor).first else {
      return MosaicStagedDocumentDeletion(didFindDocument: false, chunkIDs: [])
    }

    do {
      var chunkIDs: Set<UUID> = []
      let chunkDescriptor = FetchDescriptor<DocumentChunkRecord>(
        predicate: #Predicate { $0.documentID == targetID }
      )
      try modelContext.enumerate(
        chunkDescriptor,
        batchSize: 256,
        allowEscapingMutations: true
      ) { chunk in
        try Task.checkCancellation()
        chunkIDs.insert(chunk.id)
        modelContext.delete(chunk)
      }
      if let binding = try ProjectBindingStore.binding(
        resourceKind: .document,
        resourceID: document.id,
        in: modelContext,
        includesPendingChanges: false
      ) {
        modelContext.delete(binding)
      }
      modelContext.delete(document)
      try Task.checkCancellation()
      return MosaicStagedDocumentDeletion(didFindDocument: true, chunkIDs: chunkIDs)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  func commitStagedDeletion() throws {
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  func rollbackStagedDeletion() {
    modelContext.rollback()
  }

}

struct MosaicDocumentVectorReference: Sendable {
  let id: UUID
  let cacheKey: String
  let sourceID: UUID
}

@ModelActor
actor MosaicDocumentVectorDeletionRepository {
  /// Scans with stable keyset pages before mutating the cache. SwiftData can otherwise advance a
  /// limited fetch past rows deleted in the same model executor and skip a later page. Only cache
  /// keys for the bounded target document are retained; vector blobs never leave this actor.
  func deleteDocumentChunkVectors(
    sourceIDs: Set<UUID>,
    batchSize requestedBatchSize: Int
  ) throws -> Int {
    guard !sourceIDs.isEmpty else { return 0 }
    let batchSize = min(64, max(1, requestedBatchSize))
    var cursor: UUID?
    var targetCacheKeys: [String] = []

    while true {
      let page = try page(after: cursor, batchSize: batchSize)
      guard let nextCursor = page.last?.id else { break }
      targetCacheKeys.append(
        contentsOf: page.compactMap {
          sourceIDs.contains($0.sourceID) ? $0.cacheKey : nil
        }
      )
      cursor = nextCursor
      if page.count < batchSize { break }
    }

    var deletedCount = 0
    do {
      for (index, cacheKey) in targetCacheKeys.enumerated() {
        let targetKey = cacheKey
        var descriptor = FetchDescriptor<EmbeddingVectorRecord>(
          predicate: #Predicate { $0.cacheKey == targetKey }
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = false
        if let vector = try modelContext.fetch(descriptor).first {
          modelContext.delete(vector)
          deletedCount += 1
        }
        if (index + 1).isMultiple(of: batchSize), modelContext.hasChanges {
          try modelContext.save()
        }
      }
      if modelContext.hasChanges { try modelContext.save() }
      return deletedCount
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private func page(after cursor: UUID?, batchSize: Int) throws
    -> [MosaicDocumentVectorReference]
  {
    let sourceKind = RetrievalSourceKind.documentChunk.rawValue
    let descriptor: FetchDescriptor<EmbeddingVectorRecord>
    if let cursor {
      let currentCursor = cursor
      descriptor = FetchDescriptor(
        predicate: #Predicate {
          $0.sourceKindRawValue == sourceKind && $0.id > currentCursor
        },
        sortBy: [SortDescriptor(\EmbeddingVectorRecord.id)]
      )
    } else {
      descriptor = FetchDescriptor(
        predicate: #Predicate { $0.sourceKindRawValue == sourceKind },
        sortBy: [SortDescriptor(\EmbeddingVectorRecord.id)]
      )
    }
    var pageDescriptor = descriptor
    pageDescriptor.fetchLimit = batchSize
    pageDescriptor.includePendingChanges = false
    return try modelContext.fetch(pageDescriptor).map {
      MosaicDocumentVectorReference(id: $0.id, cacheKey: $0.cacheKey, sourceID: $0.sourceID)
    }
  }
}

enum MosaicDocumentDeletionPipeline {
  nonisolated static func delete(
    documentID: UUID,
    sourceRepository: MosaicDocumentSourceDeletionRepository,
    vectorRepository: MosaicDocumentVectorDeletionRepository,
    vectorBatchSize: Int = 64,
    commitWillBegin: @escaping @MainActor @Sendable () throws -> Void = {}
  ) async throws -> MosaicDocumentDeletionOutcome {
    let staged = try await sourceRepository.stageDeletion(documentID: documentID)
    guard staged.didFindDocument else {
      return MosaicDocumentDeletionOutcome(
        didDeleteDocument: false,
        vectorCleanupSucceeded: true,
        deletedVectorCount: 0
      )
    }

    do {
      try Task.checkCancellation()
      try await commitWillBegin()
    } catch {
      await sourceRepository.rollbackStagedDeletion()
      throw error
    }
    try await sourceRepository.commitStagedDeletion()

    do {
      let deletedVectorCount = try await vectorRepository.deleteDocumentChunkVectors(
        sourceIDs: staged.chunkIDs,
        batchSize: vectorBatchSize
      )
      return MosaicDocumentDeletionOutcome(
        didDeleteDocument: true,
        vectorCleanupSucceeded: true,
        deletedVectorCount: deletedVectorCount
      )
    } catch {
      return MosaicDocumentDeletionOutcome(
        didDeleteDocument: true,
        vectorCleanupSucceeded: false,
        deletedVectorCount: 0
      )
    }
  }
}
