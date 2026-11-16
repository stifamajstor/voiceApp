import Foundation

@MainActor
public final class DictationDelivery {
    private let history: DictationHistory
    private let dictionary: UserDictionary
    private let cloudCorrection: (any CloudCorrecting)?

    public init(
        history: DictationHistory,
        dictionary: UserDictionary,
        cloudCorrection: (any CloudCorrecting)? = nil
    ) {
        self.history = history
        self.dictionary = dictionary
        self.cloudCorrection = cloudCorrection
    }

    public func deliver(
        rawText: String,
        appBundleID: String?,
        appName: String?,
        modelID: String,
        durationSeconds: Double,
        destination: CaptureDestination = .dictation,
        paste: (String) async throws -> Void
    ) async throws -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.isNonSpeechMarker(text) else {
            return false
        }

        let dictionaryText = dictionary.correct(text).text
        let outcome: CorrectionOutcome
        if let cloudCorrection {
            outcome = await cloudCorrection.correct(
                dictionaryText,
                dictionaryTerms: dictionary.terms.map(\.text),
                appBundleID: appBundleID,
                appName: appName
            )
        } else {
            outcome = CorrectionOutcome(outputText: dictionaryText)
        }

        let completed = CompletedDictation(
            rawText: rawText,
            finalText: outcome.outputText,
            appBundleID: appBundleID,
            appName: appName,
            modelID: modelID,
            durationSeconds: durationSeconds,
            correctionInputText: outcome.inputText,
            correctionProvider: outcome.provider?.rawValue,
            correctionModel: outcome.modelID,
            correctionStatus: outcome.status?.rawValue,
            correctionReason: outcome.reason
        )
        try await history.deliver(completed, destination: destination, paste: paste)
        return true
    }

    public static func isNonSpeechMarker(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        return (first == "[" && last == "]") || (first == "(" && last == ")")
    }
}
