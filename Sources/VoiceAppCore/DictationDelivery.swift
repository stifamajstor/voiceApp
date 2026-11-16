import Foundation

@MainActor
public final class DictationDelivery {
    private let history: DictationHistory
    private let dictionary: UserDictionary

    public init(history: DictationHistory, dictionary: UserDictionary) {
        self.history = history
        self.dictionary = dictionary
    }

    public func deliver(
        rawText: String,
        appBundleID: String?,
        appName: String?,
        modelID: String,
        durationSeconds: Double,
        paste: (String) async throws -> Void
    ) async throws -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.isNonSpeechMarker(text) else {
            return false
        }

        let correctedText = dictionary.correct(text).text
        let completed = CompletedDictation(
            rawText: rawText,
            finalText: correctedText,
            appBundleID: appBundleID,
            appName: appName,
            modelID: modelID,
            durationSeconds: durationSeconds
        )
        try await history.deliver(completed, paste: paste)
        return true
    }

    public static func isNonSpeechMarker(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        return (first == "[" && last == "]") || (first == "(" && last == ")")
    }
}
