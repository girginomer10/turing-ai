import Foundation
import SwiftData

/// V5 sidecars keep the shipped provider/task entities unchanged for store migration.
@Model
public final class ProviderModelRecord {
  @Attribute(.unique) public var id: UUID
  @Attribute(.unique) public var selectionKey: String
  public var providerConfigurationID: UUID
  public var modelIdentifier: String
  public var isEnabled: Bool
  public var contextWindowTokens: Int?
  public var maximumOutputTokens: Int?

  public init(
    id: UUID = UUID(), providerConfigurationID: UUID, modelIdentifier: String,
    isEnabled: Bool = false, contextWindowTokens: Int? = nil, maximumOutputTokens: Int? = nil
  ) {
    self.id = id
    self.selectionKey = Self.key(providerID: providerConfigurationID, model: modelIdentifier)
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
    self.isEnabled = isEnabled
    self.contextWindowTokens = contextWindowTokens
    self.maximumOutputTokens = maximumOutputTokens
  }

  public static func key(providerID: UUID, model: String) -> String {
    providerID.uuidString + ":" + model
  }
}

@Model
public final class ScheduledTaskModelRecord {
  @Attribute(.unique) public var taskID: UUID
  public var providerConfigurationID: UUID
  public var modelIdentifier: String

  public init(taskID: UUID, providerConfigurationID: UUID, modelIdentifier: String) {
    self.taskID = taskID
    self.providerConfigurationID = providerConfigurationID
    self.modelIdentifier = modelIdentifier
  }
}

public struct ChatModelChoice: Identifiable, Hashable, Sendable {
  public var id: String { ProviderModelRecord.key(providerID: providerID, model: modelIdentifier) }
  public let providerID: UUID
  public let providerName: String
  public let providerKind: ProviderKind
  public let modelIdentifier: String
}

enum ProviderModelSelectionError: LocalizedError {
  case unavailable
  var errorDescription: String? {
    "This model is disabled or unavailable. Choose an enabled model, or enable it in Providers."
  }
}

@MainActor
enum ProviderModelStore {
  static func records(providerID: UUID, in context: ModelContext) throws -> [ProviderModelRecord] {
    try context.fetch(
      FetchDescriptor(
        predicate: #Predicate<ProviderModelRecord> {
          $0.providerConfigurationID == providerID
        }, sortBy: [SortDescriptor(\ProviderModelRecord.modelIdentifier)]))
  }

  static func choices(providers: [ProviderConfigurationRecord], models: [ProviderModelRecord])
    -> [ChatModelChoice]
  {
    providers.filter { $0.isEnabled && $0.provider.supportsChat }.flatMap { provider in
      let managed = models.filter { $0.providerConfigurationID == provider.id }
      // A legacy connection retains exactly its existing model until its catalog is managed.
      let identifiers =
        managed.isEmpty
        ? [provider.modelIdentifier] : managed.filter(\.isEnabled).map(\.modelIdentifier)
      return identifiers.filter { !$0.isEmpty }.sorted().map {
        ChatModelChoice(
          providerID: provider.id, providerName: provider.displayName,
          providerKind: provider.provider, modelIdentifier: $0)
      }
    }.sorted {
      if $0.modelIdentifier == $1.modelIdentifier { return $0.providerName < $1.providerName }
      return $0.modelIdentifier.localizedStandardCompare($1.modelIdentifier) == .orderedAscending
    }
  }

  static func connection(
    provider: ProviderConfigurationRecord, modelIdentifier: String,
    models: [ProviderModelRecord]
  ) throws -> ProviderConnection {
    let managed = models.filter { $0.providerConfigurationID == provider.id }
    let model = managed.first { $0.modelIdentifier == modelIdentifier }
    guard provider.isEnabled, provider.provider.supportsChat,
      managed.isEmpty ? modelIdentifier == provider.modelIdentifier : model?.isEnabled == true,
      !modelIdentifier.isEmpty
    else { throw ProviderModelSelectionError.unavailable }
    let legacy = managed.isEmpty && modelIdentifier == provider.modelIdentifier
    return ProviderConnection(
      id: provider.id, displayName: provider.displayName,
      provider: provider.provider, baseURL: provider.baseURL, modelIdentifier: modelIdentifier,
      contextWindowTokens: legacy ? provider.contextWindowTokens : model?.contextWindowTokens,
      maximumOutputTokens: legacy ? provider.maximumOutputTokens : model?.maximumOutputTokens)
  }

  /// Creates an explicit catalog without enabling newly discovered models automatically.
  static func saveCatalog(
    provider: ProviderConfigurationRecord, identifiers: [String], enabled: Set<String>,
    reset: Bool = false, in context: ModelContext
  ) throws {
    let previous = try records(providerID: provider.id, in: context)
    if reset { previous.forEach(context.delete) }
    var existing = Dictionary(
      uniqueKeysWithValues: (reset ? [] : previous).map { ($0.modelIdentifier, $0) })
    for identifier in Set(identifiers).sorted() where !identifier.isEmpty {
      guard identifier.utf8.count <= 2_048, !identifier.contains(where: { $0.isNewline }) else {
        throw ProviderModelSelectionError.unavailable
      }
      let record: ProviderModelRecord
      if let saved = existing[identifier] {
        record = saved
      } else {
        let legacy = !reset && identifier == provider.modelIdentifier
        record = ProviderModelRecord(
          providerConfigurationID: provider.id, modelIdentifier: identifier,
          contextWindowTokens: legacy ? provider.contextWindowTokens : nil,
          maximumOutputTokens: legacy ? provider.maximumOutputTokens : nil)
        context.insert(record)
        existing[identifier] = record
      }
      record.isEnabled = enabled.contains(identifier)
    }
  }

  static func setTaskModel(
    taskID: UUID, providerID: UUID, modelIdentifier: String, in context: ModelContext
  ) throws {
    let records = try context.fetch(
      FetchDescriptor<ScheduledTaskModelRecord>(predicate: #Predicate { $0.taskID == taskID }))
    if let record = records.first {
      record.providerConfigurationID = providerID
      record.modelIdentifier = modelIdentifier
    } else {
      context.insert(
        ScheduledTaskModelRecord(
          taskID: taskID, providerConfigurationID: providerID, modelIdentifier: modelIdentifier))
    }
  }

  static func taskModel(
    taskID: UUID, provider: ProviderConfigurationRecord, in context: ModelContext
  ) throws -> String {
    let record = try context.fetch(
      FetchDescriptor<ScheduledTaskModelRecord>(predicate: #Predicate { $0.taskID == taskID })
    ).first
    guard let record else { return provider.modelIdentifier }
    guard record.providerConfigurationID == provider.id else {
      throw ProviderModelSelectionError.unavailable
    }
    return record.modelIdentifier
  }
}
