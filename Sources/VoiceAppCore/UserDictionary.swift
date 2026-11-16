import Combine
import Foundation
import GRDB
import OSLog

/// Owns the live dictionary terms and prebuilt correction matcher for dictation and Settings.
@MainActor
public final class UserDictionary: ObservableObject {
    private enum LoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    public nonisolated static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30),
    ]

    @Published public private(set) var terms: [DictionaryTerm] = []
    @Published public private(set) var isLoading = true
    @Published public private(set) var isRetrying = false
    @Published public private(set) var isRetryScheduled = false
    @Published public private(set) var storeError: String?

    public var oversizedTerms: [DictionaryTerm] {
        terms.filter(\.exceedsLengthLimit)
    }

    private let repository: any DictionaryRepository
    private let timeBudget: Duration
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: (String) -> Void
    private var matcher = CorrectionMatcher.empty
    private var loadState: LoadState = .idle
    private var startTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var manualRetryTask: Task<Void, Never>?
    private var activeAttemptTask: Task<Bool, Never>?
    private var matcherGeneration = 0
    private var lastLoggedLoadError: String?

    public init(
        repository: any DictionaryRepository = SQLiteHistoryRepository(),
        timeBudget: Duration = CorrectionMatcher.defaultTimeBudget,
        retryDelays: [Duration] = UserDictionary.defaultRetryDelays,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: @escaping (String) -> Void = {
            Logger(subsystem: "com.local.voiceapp", category: "Dictionary").error("\($0, privacy: .private)")
        }
    ) {
        self.repository = repository
        self.timeBudget = timeBudget
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.log = log
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        if let startTask { return startTask }
        let task = Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.runSingleLoadAttempt()
            if !succeeded {
                self.startRetryScheduleIfNeeded()
            }
        }
        startTask = task
        return task
    }

    /// Triggers an immediate background reload if the store previously failed to load.
    public func retryLoadIfNeeded() {
        guard loadState == .failed else { return }
        guard manualRetryTask == nil, activeAttemptTask == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        isRetryScheduled = false
        manualRetryTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.runSingleLoadAttempt()
            self.manualRetryTask = nil
            if !succeeded {
                self.startRetryScheduleIfNeeded()
            }
        }
    }

    /// Runs synchronously against the prebuilt in-memory matcher without touching the store.
    public func correct(_ text: String) -> TextCorrectionResult {
        if loadState == .failed {
            retryLoadIfNeeded()
        }
        let result = matcher.correct(text, timeBudget: timeBudget)
        if result.timedOut {
            log("Dictionary correction exceeded time budget; pasted raw text.")
        }
        return result
    }

    @discardableResult
    public func addTerm(text: String, aliases: [String] = []) async throws -> DictionaryTerm {
        await ensureLoadedForEdit()
        let term = try await repository.addTerm(text: text, aliases: aliases)
        terms = Self.sorted(terms + [term])
        await rebuildMatcher()
        return term
    }

    @discardableResult
    public func updateTerm(id: UUID, text: String, aliases: [String]) async throws -> DictionaryTerm {
        await ensureLoadedForEdit()
        let updated = try await repository.updateTerm(id: id, text: text, aliases: aliases)
        if let index = terms.firstIndex(where: { $0.id == id }) {
            var next = terms
            next[index] = updated
            terms = Self.sorted(next)
        } else {
            terms = Self.sorted(terms + [updated])
        }
        await rebuildMatcher()
        return updated
    }

    public func deleteTerm(id: UUID) async throws {
        await ensureLoadedForEdit()
        try await repository.deleteTerm(id: id)
        terms.removeAll { $0.id == id }
        await rebuildMatcher()
    }

    public func errorMessage(for error: Error) -> String {
        if let dictionaryError = error as? DictionaryError {
            switch dictionaryError {
            case .emptyText:
                return dictionaryError.localizedDescription
            case .textTooLong, .aliasTooLong:
                return dictionaryError.localizedDescription
            case .conflict(let value, let termID):
                if let existing = terms.first(where: { $0.id == termID }) {
                    if DictionaryTerm.matchKey(existing.text) == DictionaryTerm.matchKey(value) {
                        return "\"\(value)\" already exists in the dictionary."
                    }
                    return "\"\(value)\" is already an alias for \"\(existing.text)\"."
                }
                return "\"\(value)\" is already used by another term or alias."
            case .termNotFound:
                return dictionaryError.localizedDescription
            }
        }
        if storeError != nil {
            return "The dictionary store is unavailable."
        }
        return "Could not save the dictionary change: \(error.localizedDescription)"
    }

    private func ensureLoadedForEdit() async {
        await start().value
        if loadState == .failed {
            _ = await runSingleLoadAttempt()
        }
    }

    private func runSingleLoadAttempt() async -> Bool {
        if loadState == .loaded { return true }
        if let activeAttemptTask {
            return await activeAttemptTask.value
        }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performLoadAttempt()
        }
        activeAttemptTask = task
        let result = await task.value
        activeAttemptTask = nil
        return result
    }

    private func performLoadAttempt() async -> Bool {
        if loadState == .loaded { return true }
        let wasRetry = (loadState == .failed)
        if wasRetry {
            isRetrying = true
        } else {
            loadState = .loading
            isLoading = true
        }
        do {
            try await repository.open()
            let loaded = try await repository.listTerms()
            let sorted = Self.sorted(loaded)
            let generation = nextMatcherGeneration()
            let built = await Self.buildMatcher(for: sorted)
            if generation == matcherGeneration {
                terms = sorted
                matcher = built
            }
            loadState = .loaded
            storeError = nil
            lastLoggedLoadError = nil
            isLoading = false
            isRetrying = false
            isRetryScheduled = false
            retryTask?.cancel()
            retryTask = nil
            if wasRetry {
                log("Loaded dictionary after retry.")
            }
            return true
        } catch {
            loadState = .failed
            isLoading = false
            isRetrying = false
            storeError = Self.storeErrorMessage(for: error)
            let message = error.localizedDescription
            if !wasRetry || lastLoggedLoadError != message {
                lastLoggedLoadError = message
                log("Could not load dictionary: \(message)")
            }
            return false
        }
    }

    private func startRetryScheduleIfNeeded() {
        guard loadState == .failed, retryTask == nil else { return }
        guard !retryDelays.isEmpty else {
            isRetryScheduled = false
            return
        }
        isRetryScheduled = true
        let delays = retryDelays
        let sleepFn = self.sleep
        retryTask = Task { [weak self] in
            defer {
                if let self {
                    self.retryTask = nil
                    self.isRetryScheduled = false
                }
            }
            for delay in delays {
                do {
                    try await sleepFn(delay)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, self.loadState == .failed else { return }
                if await self.runSingleLoadAttempt() {
                    return
                }
            }
        }
    }

    private static func isLockError(_ error: Error) -> Bool {
        if error as? MemoryStore.StoreError == .migrationLockTimeout {
            return true
        }
        if let dbError = error as? DatabaseError {
            let primary = dbError.resultCode.rawValue & 0xFF
            return primary == ResultCode.SQLITE_BUSY.rawValue || primary == ResultCode.SQLITE_LOCKED.rawValue
        }
        return false
    }

    private static func storeErrorMessage(for error: Error) -> String {
        if isLockError(error) {
            return "The dictionary database is locked. Dictation still pastes raw text; VoiceApp will retry automatically."
        }
        return "Could not load the dictionary. Dictation still pastes raw text; VoiceApp will retry automatically."
    }

    private func rebuildMatcher() async {
        let snapshot = terms
        let generation = nextMatcherGeneration()
        let built = await Self.buildMatcher(for: snapshot)
        if generation == matcherGeneration {
            matcher = built
        }
    }

    private func nextMatcherGeneration() -> Int {
        matcherGeneration += 1
        return matcherGeneration
    }

    public static func parseAliases(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }

    private static func buildMatcher(for terms: [DictionaryTerm]) async -> CorrectionMatcher {
        if terms.isEmpty { return .empty }
        return await Task.detached(priority: .userInitiated) {
            CorrectionMatcher(terms: terms)
        }.value
    }

    private static func sorted(_ terms: [DictionaryTerm]) -> [DictionaryTerm] {
        terms.sorted {
            let order = $0.text.localizedCaseInsensitiveCompare($1.text)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
