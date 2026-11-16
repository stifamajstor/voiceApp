import Combine
import Foundation

@MainActor
public final class HistoryTermination: ObservableObject {
    @Published public private(set) var isQuitPending = false
    private let history: DictationHistory
    private let showHistory: () -> Void
    private let waitForDeadline: @Sendable (Duration) async throws -> Void
    private(set) var waiting: Task<Void, Never>?
    private(set) var deadline: Task<Void, Never>?

    public init(history: DictationHistory, showHistory: @escaping () -> Void = {},
                waitForDeadline: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.history = history
        self.showHistory = showHistory
        self.waitForDeadline = waitForDeadline ?? Self.sleepBeforeDeadline
    }

    private nonisolated static let sleepBeforeDeadline: @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    }

    public func requestTermination(reply: @escaping (Bool) -> Void) -> Bool {
        guard !isQuitPending else { return false }
        guard history.pendingSave != nil else { return true }
        isQuitPending = true
        let deleteFailures = history.deleteFailures
        waiting = Task {
            while let tail = history.pendingSave, !Task.isCancelled {
                await tail.value
            }
            guard !Task.isCancelled else { return }
            finish(deleteFailures: deleteFailures, reply: reply)
        }
        deadline = Task {
            do { try await waitForDeadline(.seconds(30)) }
            catch { return }
            guard !Task.isCancelled else { return }
            finish(deleteFailures: deleteFailures, reply: reply)
        }
        return false
    }

    public func requestQuit(terminate: () -> Void) {
        // A second in-app terminate call bypasses AppKit's deferred-quit delegate.
        guard !isQuitPending else { return }
        terminate()
    }

    private func finish(deleteFailures: Int, reply: (Bool) -> Void) {
        guard waiting != nil else { return }
        waiting?.cancel()
        deadline?.cancel()
        waiting = nil
        deadline = nil
        let mayQuit = history.deleteFailures == deleteFailures
        if !mayQuit { isQuitPending = false }
        reply(mayQuit)
        if !mayQuit { showHistory() }
    }
}
