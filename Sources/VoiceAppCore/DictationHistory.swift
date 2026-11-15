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

    public static let saveEnabledKey = "saveDictationHistory"
    @Published public var saveEnabled: Bool {
        didSet {
            guard saveEnabled != oldValue else { return }
            defaults.set(saveEnabled, forKey: Self.saveEnabledKey)
            saveGeneration += 1
            if !saveEnabled { saveTasks.values.forEach { $0.cancel() } }
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
    private(set) var pendingSearch: Task<Void, Never>?
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionRecent: [Recent] = []
    private var storedRecent: [Recent] = []
    private var includeStoredRecent = true
    private var saveGeneration = 0
    private var searchGeneration = 0
    private var recentGeneration = 0
    private var resultLimit = pageSize

    public init(repository: any HistoryRepository = SQLiteHistoryRepository(), defaults: UserDefaults = .standard,
                debounce: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                log: @escaping (String) -> Void = {
                    Logger(subsystem: "com.local.voiceapp", category: "History").error("\($0, privacy: .private)")
                }) {
        self.repository = repository
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
                isOpening = false
                await refreshRecent()
            } catch {
                isOpening = false
                storeError = error.localizedDescription
                log("Could not open dictation history: \(error.localizedDescription)")
            }
        }
        openingTask = task
        return task
    }

    /// Paste completes independently of opening, saving, searching, or deleting history.
    public func deliver(_ dictation: CompletedDictation, paste: (String) async throws -> Void) async rethrows {
        let entry = Recent(id: UUID(), text: dictation.finalText, date: dictation.createdAt)
        sessionRecent.insert(entry, at: 0)
        sessionRecent = Array(sessionRecent.prefix(3))
        updateRecent()
        let enabled = saveEnabled
        let generation = saveGeneration
        defer {
            if enabled { save(dictation, recentID: entry.id, generation: generation) }
        }
        try await paste(dictation.finalText)
    }

    private func save(_ dictation: CompletedDictation, recentID: UUID, generation: Int) {
        guard saveEnabled, generation == saveGeneration else { return }
        let taskID = UUID()
        let previous = pendingSave
        let opening = start()
        pendingSave = Task {
            defer { saveTasks[taskID] = nil }
            await previous?.value
            await opening.value
            guard !Task.isCancelled, saveEnabled, generation == saveGeneration, storeError == nil else { return }
            do {
                let record = try await repository.append(dictation)
                if let index = sessionRecent.firstIndex(where: { $0.id == recentID }) {
                    sessionRecent[index] = Self.recent(record)
                }
                saveError = nil
                await refreshRecent()
                requestSearch(debounced: false)
            } catch is CancellationError {
                // Turning history off cancels saves that have not started their SQLite transaction.
            } catch {
                saveError = error.localizedDescription
                log("Could not save dictation history: \(error.localizedDescription)")
            }
        }
        saveTasks[taskID] = pendingSave
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
                searchError = error.localizedDescription
                isSearching = false
            }
        }
    }

    public func deleteSelected() async {
        let ids = selection.intersection(results.map(\.id))
        guard !ids.isEmpty else { return }
        await delete(ids: Array(ids))
    }

    public func requestDeleteAll() {
        guard !isDeleting, !isOpening, storeError == nil else { return }
        needsDeleteAllConfirmation = true
    }

    public func cancelDeleteAll() {
        needsDeleteAllConfirmation = false
    }

    public func confirmDeleteAll() async {
        guard needsDeleteAllConfirmation else { return }
        needsDeleteAllConfirmation = false
        await delete(ids: nil)
    }

    private func delete(ids: [UUID]?) async {
        guard !isDeleting, !isOpening, storeError == nil else { return }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        // Drain accepted saves so deleting history cannot be undone by an older pending save.
        await pendingSave?.value
        do {
            if let ids { try await repository.delete(ids: ids) }
            else { try await repository.deleteAll() }
            let deletedIDs = ids.map(Set.init)
            sessionRecent.removeAll { deletedIDs?.contains($0.id) ?? true }
            storedRecent.removeAll { deletedIDs?.contains($0.id) ?? true }
            selection = []
            updateRecent()
            await refreshRecent()
            await refresh()
        } catch {
            deleteError = error.localizedDescription
            log("Could not delete dictation history: \(error.localizedDescription)")
        }
    }
}
