import Foundation

public struct CompletedDictation: Sendable {
    public let id: UUID
    public let createdAt: Date
    public let rawText: String
    public let finalText: String
    public var appBundleID: String?
    public var appName: String?
    public let modelID: String
    public let durationSeconds: Double
    public let correctionInputText: String?
    public let correctionProvider: String?
    public let correctionModel: String?
    public let correctionStatus: String?
    public let correctionReason: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        rawText: String,
        finalText: String,
        appBundleID: String?,
        appName: String?,
        modelID: String,
        durationSeconds: Double,
        correctionInputText: String? = nil,
        correctionProvider: String? = nil,
        correctionModel: String? = nil,
        correctionStatus: String? = nil,
        correctionReason: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.appBundleID = appBundleID
        self.appName = appName
        self.modelID = modelID
        self.durationSeconds = durationSeconds
        self.correctionInputText = correctionInputText
        self.correctionProvider = correctionProvider
        self.correctionModel = correctionModel
        self.correctionStatus = correctionStatus
        self.correctionReason = correctionReason
    }
}

public protocol HistoryRepository: Sendable {
    func open() async throws
    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord
    func records(query: String, limit: Int) async throws -> [MemoryRecord]
    func count() async throws -> Int
    func delete(ids: [UUID]) async throws
    func deleteAll() async throws
    func appendNote(_ note: CompletedDictation) async throws
    func note(id: UUID) async throws -> VoiceNote?
    func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote]
    func editNote(id: UUID, text: String) async throws
    func setNoteDone(id: UUID, isDone: Bool) async throws
    func setNoteReminder(id: UUID, date: Date?) async throws
    func markNoteReminderScheduled(id: UUID, for date: Date?) async throws
    func markNoteReminderNotified(id: UUID, at date: Date) async throws
}

extension HistoryRepository {
    public func notes(query: String, limit: Int) async throws -> [VoiceNote] {
        try await notes(query: query, remindersOnly: false, limit: limit)
    }
    public func note(id: UUID) async throws -> VoiceNote? {
        try await notes(query: "", limit: .max).first { $0.id == id }
    }
    public func count() async throws -> Int {
        try await records(query: "", limit: .max).count
    }
}

public protocol DictionaryRepository: Sendable {
    func open() async throws
    func listTerms() async throws -> [DictionaryTerm]
    func addTerm(text: String, aliases: [String]) async throws -> DictionaryTerm
    func updateTerm(id: UUID, text: String, aliases: [String]) async throws -> DictionaryTerm
    func deleteTerm(id: UUID) async throws
}

/// Synchronous SQLite work stays on this actor, never on the UI actor.
public actor SQLiteHistoryRepository: HistoryRepository, DictionaryRepository {
    private let directory: URL
    private var store: MemoryStore?

    public init(directory: URL = MemoryStore.defaultDirectory) {
        self.directory = directory
    }

    public func open() throws {
        if store == nil { store = try MemoryStore(directory: directory) }
    }

    public func append(_ dictation: CompletedDictation) throws -> MemoryRecord {
        return try availableStore().append(
            id: dictation.id,
            kind: .dictation,
            createdAt: dictation.createdAt,
            rawText: dictation.rawText,
            finalText: dictation.finalText,
            appBundleID: dictation.appBundleID,
            appName: dictation.appName,
            modelID: dictation.modelID,
            durationSeconds: dictation.durationSeconds,
            correctionInputText: dictation.correctionInputText,
            correctionProvider: dictation.correctionProvider,
            correctionModel: dictation.correctionModel,
            correctionStatus: dictation.correctionStatus,
            correctionReason: dictation.correctionReason
        )
    }

    public func records(query: String, limit: Int) throws -> [MemoryRecord] {
        let store = try availableStore()
        return try query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.listRecent(kind: .dictation, limit: limit)
            : store.search(query, kind: .dictation, limit: limit)
    }

    public func count() throws -> Int {
        try availableStore().count(kind: .dictation)
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

    public func listTerms() throws -> [DictionaryTerm] {
        try availableStore().listTerms()
    }

    public func addTerm(text: String, aliases: [String]) throws -> DictionaryTerm {
        try availableStore().addTerm(text: text, aliases: aliases)
    }

    public func updateTerm(id: UUID, text: String, aliases: [String]) throws -> DictionaryTerm {
        try availableStore().updateTerm(id: id, text: text, aliases: aliases)
    }

    public func deleteTerm(id: UUID) throws {
        try availableStore().deleteTerm(id: id)
    }

    public func appendNote(_ note: CompletedDictation) async throws {
        try availableStore().append(id: note.id, kind: .note, createdAt: note.createdAt,
            rawText: note.rawText, finalText: note.finalText, appBundleID: note.appBundleID,
            appName: note.appName, modelID: note.modelID, durationSeconds: note.durationSeconds,
            // Notes receive only the local dictionary pass; cloud metadata is deliberately absent.
            correctionInputText: nil, correctionProvider: nil, correctionModel: nil,
            correctionStatus: nil, correctionReason: nil)
    }

    public func note(id: UUID) async throws -> VoiceNote? { try availableStore().note(id: id) }

    public func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote] {
        try availableStore().notes(query: query, remindersOnly: remindersOnly, limit: limit)
    }

    public func editNote(id: UUID, text: String) async throws { try availableStore().editNote(id: id, text: text) }
    public func setNoteDone(id: UUID, isDone: Bool) async throws { try availableStore().setNoteDone(id: id, isDone: isDone) }
    public func setNoteReminder(id: UUID, date: Date?) async throws {
        try availableStore().setNoteReminder(id: id, date: date)
    }

    public func markNoteReminderScheduled(id: UUID, for date: Date?) async throws {
        try availableStore().markNoteReminderScheduled(id: id, for: date)
    }

    public func markNoteReminderNotified(id: UUID, at date: Date) async throws {
        try availableStore().markNoteReminderNotified(id: id, at: date)
    }

    private func availableStore() throws -> MemoryStore {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        return store
    }
}
