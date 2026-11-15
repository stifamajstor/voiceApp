import Foundation

@MainActor
public final class HistoryTermination {
    private let history: DictationHistory
    private let showHistory: () -> Void
    private let waitForDeadline: @Sendable (Duration) async throws -> Void
    private(set) var waiting: Task<Void, Never>?
    private(set) var deadline: Task<Void, Never>?

    public init(history: DictationHistory, showHistory: @escaping () -> Void = {},
                waitForDeadline: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.history = history
        self.showHistory = showHistory
        self.waitForDeadline = waitForDeadline
    }

    public func requestTermination(reply: @escaping (Bool) -> Void) -> Bool {
        guard waiting == nil else { return false }
        guard history.pendingSave != nil else { return true }
        waiting = Task {
            while let tail = history.pendingSave, !Task.isCancelled {
                await tail.value
            }
            guard !Task.isCancelled else { return }
            finish(reply: reply)
        }
        deadline = Task {
            do { try await waitForDeadline(.seconds(30)) }
            catch { return }
            guard !Task.isCancelled else { return }
            finish(reply: reply)
        }
        return false
    }

    private func finish(reply: (Bool) -> Void) {
        guard waiting != nil else { return }
        waiting?.cancel()
        deadline?.cancel()
        waiting = nil
        deadline = nil
        let mayQuit = history.deleteError == nil
        reply(mayQuit)
        if !mayQuit { showHistory() }
    }
}
