import Combine
import Foundation

@MainActor
public final class DictationDelivery {
    public struct TargetChanged: LocalizedError {
        public init() {}
        public var errorDescription: String? { "Copied to clipboard — the target app changed" }
    }

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
        willCorrect: () -> Void = {},
        paste: (String) async throws -> Void
    ) async throws -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.isNonSpeechMarker(text) else {
            return false
        }

        let kind: RecordKind = destination == .dictation ? .dictation : .note

        let dictionaryResult = dictionary.correct(text)
        let dictionaryText = dictionaryResult.text
        let protectedRanges = dictionaryResult.replacements.compactMap {
            Range($0.outputRange, in: dictionaryText)
        }

        // Cloud correction runs strictly on the dictation paste path (.dictation).
        // Voice notes (.note) bypass cloud correction and remain guarded against accidental routing.
        let outcome: CorrectionOutcome
        if let cloudCorrection, kind == .dictation {
            willCorrect()
            outcome = await cloudCorrection.correct(
                dictionaryText,
                dictionaryTerms: dictionary.terms.map(\.text),
                protectedRanges: protectedRanges,
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

/// Keeps capture busy until its transcription, correction and paste have finished.
@MainActor
public final class DictationSessionCoordinator: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case correcting
        case error(String)
    }

    public typealias Trigger = CaptureTrigger

    @Published public private(set) var state: State = .idle

    public private(set) var activeTrigger: Trigger?

    public init() {}

    public func canBeginRecording(onBusy: () -> Void = {}) -> Bool {
        switch state {
        case .idle, .error:
            return true
        case .correcting:
            onBusy()
            return false
        case .recording, .transcribing:
            return false
        }
    }

    @discardableResult
    public func beginRecording(trigger: Trigger, onBusy: () -> Void = {}) -> Bool {
        guard canBeginRecording(onBusy: onBusy) else { return false }
        activeTrigger = trigger
        state = .recording
        return true
    }

    public func cancelRecording() {
        guard state == .recording else { return }
        activeTrigger = nil
        state = .idle
    }

    public func discardShortRecording() {
        guard state == .recording else { return }
        activeTrigger = nil
        state = .idle
    }

    public func beginTranscribing() -> Bool {
        guard state == .recording else { return false }
        activeTrigger = nil
        state = .transcribing
        return true
    }

    public func finishTranscribing(hasError: Bool = false) {
        guard (state == .transcribing || state == .correcting), !hasError else { return }
        state = .idle
    }

    public func setError(_ message: String) {
        activeTrigger = nil
        state = .error(message)
    }

    public func clearErrorIfShowing() {
        if case .error = state {
            state = .idle
        }
    }

    public func beginCorrecting() {
        guard state == .transcribing else { return }
        state = .correcting
    }
}
