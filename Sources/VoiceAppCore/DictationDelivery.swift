import Combine
import Foundation

@MainActor
public final class DictationDelivery {
    private let history: DictationHistory
    private let dictionary: UserDictionary
    private let cloudCorrection: (any CloudCorrecting)?
    private var lastDeliveryTicket: DeliveryTicket?

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

        let kind: RecordKind = destination == .dictation ? .dictation : .note

        // Claim this dictation's paste slot before awaiting cloud correction so
        // overlapping dictations paste strictly in submission order even when a
        // later correction completes faster.
        let previousDelivery = kind == .dictation ? lastDeliveryTicket : nil
        let currentDelivery = DeliveryTicket()
        if kind == .dictation { lastDeliveryTicket = currentDelivery }
        defer { currentDelivery.finish() }

        let dictionaryResult = dictionary.correct(text)
        let dictionaryText = dictionaryResult.text
        let protectedRanges = dictionaryResult.replacements.compactMap {
            Range($0.outputRange, in: dictionaryText)
        }

        // Cloud correction runs strictly on the dictation paste path (.dictation).
        // Voice notes (.note) bypass cloud correction and remain guarded against accidental routing.
        let outcome: CorrectionOutcome
        if let cloudCorrection, kind == .dictation {
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

        await previousDelivery?.wait()

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

@MainActor
private final class DeliveryTicket {
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !isComplete else { return }
        isComplete = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Manages dictation recording/transcription state while permitting a new recording
/// to start as soon as local transcription completes, even if an earlier dictation's
/// cloud correction or paste is still in flight.
@MainActor
public final class DictationSessionCoordinator: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    public typealias Trigger = CaptureTrigger

    @Published public private(set) var state: State = .idle
    @Published public private(set) var pendingDeliveryCount = 0

    public private(set) var activeTrigger: Trigger?

    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func canBeginRecording() -> Bool {
        switch state {
        case .idle, .error:
            return true
        case .recording, .transcribing:
            return false
        }
    }

    @discardableResult
    public func beginRecording(trigger: Trigger) -> Bool {
        guard canBeginRecording() else { return false }
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
        guard state == .transcribing, !hasError else { return }
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

    /// Launches delivery in the background after local transcription finishes so new
    /// shortcuts can start recording immediately while keeping paste FIFO-ordered.
    @discardableResult
    public func enqueueDelivery(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        pendingDeliveryCount += 1
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.pendingDeliveryCount = max(0, self.pendingDeliveryCount - 1)
                    self.deliveryTasks.removeValue(forKey: id)
                }
            }
            await work()
        }
        deliveryTasks[id] = task
        return task
    }

    public func waitForPendingDeliveries() async {
        while let task = deliveryTasks.values.first {
            await task.value
        }
    }
}
