import Foundation
import SwiftData

@ModelActor
private actor SemanticIndexMaintenanceRepository {
  func clearAll() throws {
    do {
      try Task.checkCancellation()
      try modelContext.delete(model: EmbeddingVectorRecord.self)
      try Task.checkCancellation()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }
}

/// Rebuildable vector cache kept separate from conversations and document sources.
/// If this store is removed, Mosaic can regenerate every vector from the main store.
@MainActor
public enum SemanticIndexStore {
  private static let loadedStore: (container: ModelContainer, didFallBackToMemory: Bool) = {
    let requestedInMemory = ProcessInfo.processInfo.arguments.contains("--in-memory")
    do {
      return (try makeModelContainer(inMemory: requestedInMemory), false)
    } catch {
      do {
        return (try makeModelContainer(inMemory: true), true)
      } catch {
        preconditionFailure("Turing AI could not create its semantic index: \(error)")
      }
    }
  }()

  public static var shared: ModelContainer { loadedStore.container }
  public static var didFallBackToMemory: Bool { loadedStore.didFallBackToMemory }

  public static var schema: Schema {
    Schema([EmbeddingVectorRecord.self])
  }

  public static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
    let configuration: ModelConfiguration
    if inMemory {
      configuration = ModelConfiguration(
        "MosaicSemanticIndex",
        schema: schema,
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
      )
    } else {
      let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let directory = applicationSupport.appendingPathComponent("Mosaic", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      configuration = ModelConfiguration(
        "MosaicSemanticIndex",
        schema: schema,
        url: directory.appendingPathComponent("SemanticIndex.store"),
        cloudKitDatabase: .none
      )
    }
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  /// Removes only rebuildable vectors. Source conversations, memories, and document chunks live
  /// in the main store and are never touched here.
  public static func clearAll() throws {
    let context = shared.mainContext
    do {
      try context.delete(model: EmbeddingVectorRecord.self)
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
  }

  /// Clears a potentially large rebuildable cache on its own SwiftData executor.
  public static func clearAllAsync() async throws {
    let repository = SemanticIndexMaintenanceRepository(modelContainer: shared)
    try await repository.clearAll()
  }
}
