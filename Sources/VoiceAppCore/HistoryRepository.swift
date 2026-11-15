import Foundation

public struct CompletedDictation: Sendable {
    public let createdAt: Date
    public let rawText: String
    public let finalText: String
    public let appBundleID: String?
    public let appName: String?
    public let modelID: String
    public let durationSeconds: Double

    public init(createdAt: Date = .now, rawText: String, finalText: String,
                appBundleID: String?, appName: String?, modelID: String, durationSeconds: Double) {
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.appBundleID = appBundleID
        self.appName = appName
        self.modelID = modelID
        self.durationSeconds = durationSeconds
    }
}

public protocol HistoryRepository: Sendable {
    func open() async throws
    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord
    func records(query: String, limit: Int) async throws -> [MemoryRecord]
    func delete(ids: [UUID]) async throws
    func deleteAll() async throws
}

/// Synchronous SQLite work stays on this actor, never on the UI actor.
public actor SQLiteHistoryRepository: HistoryRepository {
    private let directory: URL
    private var store: MemoryStore?

    public init(directory: URL = MemoryStore.defaultDirectory) {
        self.directory = directory
    }

    public func open() throws {
        if store == nil { store = try MemoryStore(directory: directory) }
    }

    public func append(_ dictation: CompletedDictation) throws -> MemoryRecord {
        try Task.checkCancellation()
        return try availableStore().append(kind: .dictation, createdAt: dictation.createdAt,
            rawText: dictation.rawText, finalText: dictation.finalText,
            appBundleID: dictation.appBundleID, appName: dictation.appName,
            modelID: dictation.modelID, durationSeconds: dictation.durationSeconds)
    }

    public func records(query: String, limit: Int) throws -> [MemoryRecord] {
        let store = try availableStore()
        return try query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.listRecent(kind: .dictation, limit: limit)
            : store.search(query, kind: .dictation, limit: limit)
    }

    public func delete(ids: [UUID]) throws {
        try availableStore().delete(ids: ids)
    }

    public func deleteAll() throws {
        let store = try availableStore()
        // The app's single repository serializes appends with this snapshot and batch delete.
        let ids = try store.listRecent(kind: .dictation, limit: .max).map(\.id)
        try store.delete(ids: ids)
    }

    private func availableStore() throws -> MemoryStore {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        return store
    }
}
