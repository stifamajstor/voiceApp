/// Keeps the previous assignment when a recorder proposes an already assigned combination.
public enum ShortcutValidation {
    public static func resolve<Value: Equatable>(candidate: Value?, previous: Value?, others: [Value?])
        -> (value: Value?, message: String?) {
        if let candidate, others.contains(where: { $0 == candidate }) {
            return (previous, "That shortcut is already used. Choose a different combination.")
        }
        return (candidate, nil)
    }

    /// Positions whose binding equals the one at `index`. Recorders only check at the moment of recording, so a
    /// duplicate saved by an earlier build is found this way when Settings opens.
    public static func conflicts<Value: Equatable>(of index: Int, in bindings: [Value?]) -> [Int] {
        guard bindings.indices.contains(index), let mine = bindings[index] else { return [] }
        return bindings.indices.filter { $0 != index && bindings[$0] == mine }
    }
}
