import Foundation

@MainActor
public final class HistoryTermination {
    private let history: DictationHistory
    private var waiting: Task<Void, Never>?

    public init(history: DictationHistory) {
        self.history = history
    }

    public func requestTermination(reply: @escaping (Bool) -> Void) -> Bool {
        guard waiting == nil else { return false }
        guard history.pendingDeletion != nil else { return true }
        waiting = Task {
            while let deletion = history.pendingDeletion { await deletion.value }
            waiting = nil
            reply(history.deleteError == nil)
        }
        return false
    }
}
