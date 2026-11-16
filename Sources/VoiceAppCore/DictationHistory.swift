import Combine
import Foundation
import OSLog

@MainActor
public final class DictationHistory: ObservableObject {
    public struct Recent: Identifiable, Equatable {
        public let id: UUID
        public let text: String
        public let date: Date
    }

    @Published public private(set) var notes: [VoiceNote] = []
    @Published public private(set) var noteDeleteError: String?
    @Published public private(set) var noteSearchError: String?
    @Published public private(set) var noteError: String?
    @Published public private(set) var noteFeedback: String?
    @Published public private(set) var reminderAccessDenied = false
    @Published public private(set) var pendingNoteOperations = 0
    @Published public private(set) var isSearchingNotes = false
    @Published public private(set) var hasMoreNotes = false
    @Published public var noteQuery = "" {
        didSet {
            noteLimit = Self.pageSize
            searchNotes(debounced: true)
        }
    }
    @Published public private(set) var noteToDelete: VoiceNote?
    @Published public var isNoteDeleteConfirmationPresented = false
    private var noteLimit = pageSize
    private var noteSearchGeneration = 0
    private var pendingNoteSearch: Task<Void, Never>?
    private var noteFeedbackTask: Task<Void, Never>?
    private let reminders: any NoteReminderService

    public static let saveEnabledKey = "saveDictationHistory"
    @Published public var saveEnabled: Bool {
        didSet {
            guard saveEnabled != oldValue else { return }
            defaults.set(saveEnabled, forKey: Self.saveEnabledKey)
            updateRecent()
            if saveEnabled { Task { await refreshRecent() } }
        }
    }
    @Published public private(set) var isOpening = true
    @Published public private(set) var storeError: String?
    @Published public private(set) var saveError: String?
    @Published public private(set) var recent: [Recent] = []
    @Published public private(set) var results: [MemoryRecord] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var isDeleting = false
    @Published public private(set) var deleteError: String?
    @Published public private(set) var searchError: String?
    @Published public private(set) var hasMore = false
    @Published public private(set) var needsDeleteAllConfirmation = false
    @Published public private(set) var needsDeleteSelectedConfirmation = false
    // SwiftUI dismisses the alert binding independently of its confirmation action.
    @Published public var isDeleteConfirmationPresented = false
    @Published private var storedCount = 0
    @Published private var pendingDictations: Set<UUID> = []
    private var selectedDeletionIDs: Set<UUID> = []

    public var savingDisclosure: String {
        if storeError != nil || saveError != nil {
            return "Dictation history is not being saved. Dictation still works. The cause is in the log."
        }
        return saveEnabled
            ? "Dictations are saved on this Mac. Turn off in Settings → Behavior."
            : "New dictations are not saved. Turn on in Settings → Behavior."
    }

    public var deleteConfirmationTitle: String {
        let count = needsDeleteAllConfirmation ? deleteAllCount : selectedDeleteCount
        return "Delete \(count) \(count == 1 ? "dictation" : "dictations")?"
    }

    public var selectedDeleteCount: Int { selectedDeletionIDs.count }
    public var deleteAllCount: Int { storedCount + pendingDictations.count }
    @Published public var selection: Set<UUID> = []
    @Published public var query = "" {
        didSet {
            resultLimit = Self.pageSize
            requestSearch(debounced: true)
        }
    }

    private static let pageSize = 100
    private let repository: any HistoryRepository
    private let defaults: UserDefaults
    private let debounce: @Sendable (Duration) async throws -> Void
    private let log: (String) -> Void
    private var openingTask: Task<Void, Never>?
    private(set) var pendingSave: Task<Void, Never>?
    private var saveGeneration = 0
    public private(set) var pendingDeletion: Task<Void, Never>?
    private(set) var deleteFailures = 0
    private(set) var pendingSearch: Task<Void, Never>?
    private var sessionRecent: [Recent] = []
    private var storedRecent: [Recent] = []
    private var includeStoredRecent = true
    private var searchGeneration = 0
    private var recentGeneration = 0
    private var resultLimit = pageSize

    public init(repository: any HistoryRepository = SQLiteHistoryRepository(),
                reminders: (any NoteReminderService)? = nil, defaults: UserDefaults = .standard,
                debounce: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                log: @escaping (String) -> Void = {
                    Logger(subsystem: "com.local.voiceapp", category: "History").error("\($0, privacy: .private)")
                }) {
        self.repository = repository
        self.reminders = reminders ?? EventKitNoteReminders()
        self.defaults = defaults
        self.debounce = debounce
        self.log = log
        saveEnabled = defaults.object(forKey: Self.saveEnabledKey) as? Bool ?? true
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        if let openingTask { return openingTask }
        let task = Task {
            do {
                try await repository.open()
                storedCount = try await repository.count()
                isOpening = false
                await refreshRecent()
            } catch {
                isOpening = false
                storeError = error as? MemoryStore.StoreError == .migrationLockTimeout
                    ? "Opening dictation history timed out. History is not being saved; dictation still works. The cause is in the log. Relaunch VoiceApp to try opening it again."
                    : "Could not open dictation history. History is not being saved; dictation still works. The cause is in the log."
                log("Could not open dictation history: \(error.localizedDescription)")
            }
        }
        openingTask = task
        return task
    }

    /// Paste completes independently of opening, saving, searching, or deleting history.
    public func deliver(_ dictation: CompletedDictation, destination: CaptureDestination = .dictation, paste: (String) async throws -> Void) async rethrows {
        if destination == .note {
            enqueueNoteOperation {
                try await self.repository.appendNote(dictation)
                self.noteFeedbackTask?.cancel()
                self.noteFeedback = "Note saved"
                self.noteFeedbackTask = Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    self.noteFeedback = nil
                }
            }
            return
        }
        let entry = Recent(id: dictation.id, text: dictation.finalText, date: dictation.createdAt)
        sessionRecent.insert(entry, at: 0)
        sessionRecent = Array(sessionRecent.prefix(3))
        updateRecent()
        let enabled = saveEnabled
        defer {
            if enabled { save(dictation) }
        }
        try await paste(dictation.finalText)
    }

    private func save(_ dictation: CompletedDictation) {
        pendingDictations.insert(dictation.id)
        saveGeneration += 1
        let generation = saveGeneration
        let previous = pendingSave
        let opening = start()
        pendingSave = Task {
            defer {
                pendingDictations.remove(dictation.id)
                if generation == saveGeneration { pendingSave = nil }
            }
            await previous?.value
            await opening.value
            guard storeError == nil else { return }
            do {
                _ = try await repository.append(dictation)
                storedCount += 1
                pendingDictations.remove(dictation.id)
                saveError = nil
                await refreshRecent()
                requestSearch(debounced: false)
            } catch {
                saveError = "Could not save this dictation. History is not being saved; dictation still works. The cause is in the log."
                log("Could not save dictation history: \(error.localizedDescription)")
            }
        }
    }

    public func clearRecent() {
        includeStoredRecent = false
        sessionRecent = []
        storedRecent = []
        updateRecent()
    }

    public func refreshRecent() async {
        guard !isOpening, storeError == nil, saveEnabled, includeStoredRecent else { return }
        recentGeneration += 1
        let generation = recentGeneration
        do {
            let records = try await repository.records(query: "", limit: 3)
            guard generation == recentGeneration, saveEnabled, includeStoredRecent else { return }
            storedRecent = records.map(Self.recent)
            updateRecent()
        } catch {
            log("Could not read recent dictations: \(error.localizedDescription)")
        }
    }

    private func updateRecent() {
        let sessionIDs = Set(sessionRecent.map(\.id))
        let stored = saveEnabled && includeStoredRecent ? storedRecent.filter { !sessionIDs.contains($0.id) } : []
        recent = Array((sessionRecent + stored).prefix(3))
    }

    private static func recent(_ record: MemoryRecord) -> Recent {
        Recent(id: record.id, text: record.finalText, date: record.createdAt)
    }

    public func refresh() async {
        requestSearch(debounced: false)
        await pendingSearch?.value
    }

    public func loadMore() async {
        guard hasMore, !isSearching, !isDeleting else { return }
        resultLimit += Self.pageSize
        await refresh()
    }

    private func requestSearch(debounced: Bool) {
        pendingSearch?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let query = query
        let limit = resultLimit
        isSearching = true
        pendingSearch = Task {
            do {
                if debounced { try await debounce(.milliseconds(250)) }
                await start().value
                guard !Task.isCancelled, generation == searchGeneration else { return }
                guard storeError == nil else {
                    isSearching = false
                    return
                }
                let records = try await repository.records(query: query, limit: limit + 1)
                guard !Task.isCancelled, generation == searchGeneration else { return }
                results = Array(records.prefix(limit))
                hasMore = records.count > limit
                selection.formIntersection(results.map(\.id))
                searchError = nil
                isSearching = false
            } catch {
                guard !Task.isCancelled, generation == searchGeneration else { return }
                results = []
                hasMore = false
                selection = []
                searchError = "Could not search dictation history. Try again. The cause is in the log."
                log("Could not search dictation history: \(error.localizedDescription)")
                isSearching = false
            }
        }
    }

    public func requestDeleteSelected() {
        guard !isDeleting, !isSearching, !isOpening, storeError == nil else { return }
        cancelDeleteAll()
        selectedDeletionIDs = selection.intersection(results.map(\.id))
        needsDeleteSelectedConfirmation = !selectedDeletionIDs.isEmpty
        isDeleteConfirmationPresented = needsDeleteSelectedConfirmation
    }

    public func cancelDeleteSelected() {
        isDeleteConfirmationPresented = false
        needsDeleteSelectedConfirmation = false
        selectedDeletionIDs = []
    }

    @discardableResult
    public func deleteSelected() -> Task<Void, Never>? {
        guard needsDeleteSelectedConfirmation else { return nil }
        let ids = Array(selectedDeletionIDs)
        cancelDeleteSelected()
        return delete(ids: ids)
    }

    public func requestDeleteAll() {
        guard !isDeleting, !isOpening, storeError == nil else { return }
        cancelDeleteSelected()
        needsDeleteAllConfirmation = true
        isDeleteConfirmationPresented = true
    }

    public func cancelDeleteAll() {
        isDeleteConfirmationPresented = false
        needsDeleteAllConfirmation = false
    }

    @discardableResult
    public func confirmDeleteAll() -> Task<Void, Never>? {
        guard needsDeleteAllConfirmation else { return nil }
        cancelDeleteAll()
        return delete(ids: nil)
    }

    private func delete(ids: [UUID]?) -> Task<Void, Never>? {
        guard !isDeleting, !isOpening, storeError == nil else { return nil }
        isDeleting = true
        deleteError = nil
        saveGeneration += 1
        let generation = saveGeneration
        let previous = pendingSave
        let recentIDs = Set(sessionRecent.map(\.id))
        let deletion = Task {
            defer {
                isDeleting = false
                pendingDeletion = nil
                if generation == saveGeneration { pendingSave = nil }
            }
            await previous?.value
            do {
                if let ids { try await repository.delete(ids: ids) }
                else { try await repository.deleteAll() }
                storedCount = ids.map { max(0, storedCount - $0.count) } ?? 0
                let deletedIDs = ids.map(Set.init) ?? recentIDs
                sessionRecent.removeAll { deletedIDs.contains($0.id) }
                storedRecent.removeAll { ids == nil || deletedIDs.contains($0.id) }
                selection = []
                updateRecent()
                await refreshRecent()
                await refresh()
            } catch {
                deleteFailures += 1
                deleteError = "Could not delete dictation history. Try again. The cause is in the log."
                log("Could not delete dictation history: \(error.localizedDescription)")
            }
        }
        // Later saves must follow the delete, including its menu refresh.
        pendingSave = deletion
        pendingDeletion = deletion
        return deletion
    }

    public func refreshNotes() async {
        searchNotes(debounced: false)
        await pendingNoteSearch?.value
    }

    public func loadMoreNotes() async {
        guard hasMoreNotes, !isSearchingNotes else { return }
        noteLimit += Self.pageSize
        await refreshNotes()
    }

    private func searchNotes(debounced: Bool) {
        pendingNoteSearch?.cancel()
        noteSearchGeneration += 1
        let generation = noteSearchGeneration
        let query = noteQuery
        let limit = noteLimit
        isSearchingNotes = true
        pendingNoteSearch = Task {
            defer { if generation == noteSearchGeneration { isSearchingNotes = false } }
            do {
                if debounced { try await debounce(.milliseconds(250)) }
                await start().value
                guard !Task.isCancelled, generation == noteSearchGeneration, storeError == nil else { return }
                let result = try await repository.notes(query: query, limit: limit + 1)
                guard !Task.isCancelled, generation == noteSearchGeneration else { return }
                notes = Array(result.prefix(limit))
                hasMoreNotes = result.count > limit
                noteSearchError = nil
            } catch {
                guard !Task.isCancelled, generation == noteSearchGeneration else { return }
                notes = []
                hasMoreNotes = false
                noteSearchError = "Could not search notes. Try again."
                log("Could not search notes: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    public func editNote(id: UUID, text: String, completion: ((String?) -> Void)? = nil) -> Task<Void, Never> {
        enqueueNoteOperation(completion: completion) { try await self.repository.editNote(id: id, text: text) }
    }

    @discardableResult
    public func setNoteDone(id: UUID, isDone: Bool) -> Task<Void, Never> {
        enqueueNoteOperation { try await self.repository.setNoteDone(id: id, isDone: isDone) }
    }

    public func requestDeleteNote(_ note: VoiceNote) {
        noteToDelete = note
        isNoteDeleteConfirmationPresented = true
    }
    public func cancelDeleteNote() {
        noteToDelete = nil
        isNoteDeleteConfirmationPresented = false
    }

    @discardableResult
    public func confirmDeleteNote() -> Task<Void, Never>? {
        guard let note = noteToDelete else { return nil }
        cancelDeleteNote()
        return enqueueNoteOperation(isDeletion: true) {
            if let identifier = try await self.currentNote(id: note.id).reminderID {
                try await self.requireReminderAccess()
                try self.reminders.remove(identifier: identifier)
            }
            try await self.repository.delete(ids: [note.id])
        }
    }

    @discardableResult
    public func remindNote(id: UUID, date: Date) -> Task<Void, Never> {
        enqueueNoteOperation {
            let note = try await self.currentNote(id: id)
            guard note.reminderID == nil else { return }
            try await self.requireReminderAccess()
            let identifier = try self.reminders.create(title: note.text, date: date)
            do {
                try await self.repository.setNoteReminder(id: id, identifier: identifier, date: date)
            } catch {
                do { try self.reminders.remove(identifier: identifier) }
                catch {
                    throw NSError(domain: "VoiceApp.Reminders", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Could not save the reminder link or remove the new reminder. Remove it in Apple Reminders before trying again."])
                }
                throw error
            }
        }
    }

    @discardableResult
    public func undoNoteReminder(id: UUID) -> Task<Void, Never> {
        enqueueNoteOperation {
            guard let identifier = try await self.currentNote(id: id).reminderID else { return }
            try await self.requireReminderAccess()
            try self.reminders.remove(identifier: identifier)
            try await self.repository.setNoteReminder(id: id, identifier: nil, date: nil)
        }
    }

    private func currentNote(id: UUID) async throws -> VoiceNote {
        guard let note = try await repository.note(id: id)
        else { throw NoteError.notFound }
        return note
    }

    private func requireReminderAccess() async throws {
        guard try await reminders.requestAccess() else {
            reminderAccessDenied = true
            throw ReminderError.accessDenied
        }
        reminderAccessDenied = false
    }

    @discardableResult
    private func enqueueNoteOperation(isDeletion: Bool = false, completion: ((String?) -> Void)? = nil,
                                      _ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let previous = pendingSave
        let opening = start()
        saveGeneration += 1
        let generation = saveGeneration
        pendingNoteOperations += 1
        let task = Task {
            var failure: String?
            defer {
                completion?(failure)
                pendingNoteOperations -= 1
                if generation == saveGeneration { pendingSave = nil }
            }
            await previous?.value
            await opening.value
            guard storeError == nil else {
                let message = "Could not open the notes store. Relaunch VoiceApp to try again."
                failure = message
                if isDeletion { deleteFailures += 1; noteDeleteError = message }
                else { noteError = message }
                return
            }
            do {
                try await operation()
                noteError = nil
                if isDeletion { noteDeleteError = nil }
                await refreshNotes()
            } catch {
                let message = "Could not update notes: \(error.localizedDescription)"
                failure = message
                if isDeletion { deleteFailures += 1; noteDeleteError = message }
                else { noteError = message }
                log("Could not update notes: \(error.localizedDescription)")
            }
        }
        pendingSave = task
        return task
    }
}
