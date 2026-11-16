/// Keeps the previous assignment when a recorder proposes an already assigned combination.
public enum ShortcutValidation {
    public static func resolve<Value: Equatable>(candidate: Value?, previous: Value?, others: [Value?])
        -> (value: Value?, message: String?) {
        if let candidate, others.contains(where: { $0 == candidate }) {
            return (previous, "That shortcut is already used. Choose a different combination.")
        }
        return (candidate, nil)
    }
}
