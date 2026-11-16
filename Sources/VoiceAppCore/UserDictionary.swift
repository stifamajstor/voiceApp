import Combine
import Foundation
import OSLog

/// Owns the live dictionary terms and prebuilt correction matcher for dictation and Settings.
@MainActor
public final class UserDictionary: ObservableObject {
    @Published public private(set) var terms: [DictionaryTerm] = []
    @Published public private(set) var isLoading = true
    @Published public private(set) var storeError: String?

    private let repository: any DictionaryRepository
    private let log: (String) -> Void
    private var matcher = CorrectionMatcher.empty
    private var startTask: Task<Void, Never>?
    private var matcherGeneration = 0

    public init(
        repository: any DictionaryRepository = SQLiteHistoryRepository(),
        log: @escaping (String) -> Void = {
            Logger(subsystem: "com.local.voiceapp", category: "Dictionary").error("\($0, privacy: .private)")
        }
    ) {
        self.repository = repository
        self.log = log
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        if let startTask { return startTask }
        let task = Task {
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
                storeError = nil
                isLoading = false
            } catch {
                isLoading = false
                storeError = error as? MemoryStore.StoreError == .migrationLockTimeout
                    ? "Opening the dictionary timed out. Dictation still works without dictionary replacements. The cause is in the log. Relaunch VoiceApp to try opening it again."
                    : "Could not load the dictionary. Dictation still works without dictionary replacements. The cause is in the log."
                log("Could not load dictionary: \(error.localizedDescription)")
            }
        }
        startTask = task
        return task
    }

    /// Runs synchronously against the prebuilt in-memory matcher without touching the store.
    public func correct(_ text: String) -> TextCorrectionResult {
        matcher.correct(text)
    }

    @discardableResult
    public func addTerm(text: String, aliases: [String] = []) async throws -> DictionaryTerm {
        await start().value
        let term = try await repository.addTerm(text: text, aliases: aliases)
        terms = Self.sorted(terms + [term])
        await rebuildMatcher()
        return term
    }

    @discardableResult
    public func updateTerm(id: UUID, text: String, aliases: [String]) async throws -> DictionaryTerm {
        await start().value
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
        await start().value
        try await repository.deleteTerm(id: id)
        terms.removeAll { $0.id == id }
        await rebuildMatcher()
    }

    public func errorMessage(for error: Error) -> String {
        if let dictionaryError = error as? DictionaryError {
            switch dictionaryError {
            case .emptyText:
                return "Term text cannot be blank."
            case .conflict(let value, let termID):
                if let existing = terms.first(where: { $0.id == termID }) {
                    if DictionaryTerm.matchKey(existing.text) == DictionaryTerm.matchKey(value) {
                        return "\"\(value)\" already exists in the dictionary."
                    }
                    return "\"\(value)\" is already an alias for \"\(existing.text)\"."
                }
                return "\"\(value)\" is already used by another term or alias."
            case .termNotFound:
                return "This term no longer exists."
            }
        }
        if storeError != nil {
            return "The dictionary store is unavailable."
        }
        return "Could not save the dictionary change: \(error.localizedDescription)"
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
