import AppKit
import Foundation
import VoiceAppCore

/// Orchestrates hotkey -> record -> transcribe -> cloud correct -> paste.
///
/// Capture stays busy through transcription, correction and paste. A shortcut during
/// correction gets the existing error sound; its key-up cannot cancel another recording.
@MainActor
final class DictationController: ObservableObject {
    typealias State = DictationSessionCoordinator.State

    @Published private(set) var state: State = .idle

    /// Recordings shorter than this are treated as accidental taps and dropped.
    static let minimumDuration: TimeInterval = 0.3
    /// Safety net for a lost key-up / forgotten toggle session.
    static let maximumDuration: TimeInterval = 300
    private static let errorDisplayDuration: Duration = .seconds(3)

    private var recordingAppBundleID: String?
    private var recordingAppName: String?

    private let modelManager: ModelManager
    private let delivery: DictationDelivery
    let session = DictationSessionCoordinator()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private let modifierHotkeys = ModifierHotkeyMonitor()

    private var started = false
    private var isRequestingMicrophone = false
    private var errorClearTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private(set) var transcriptionTask: Task<Void, Never>?
    var isQuitting = false
    private var promptedAccessibilityThisLaunch = false

    init(
        modelManager: ModelManager,
        history: DictationHistory,
        dictionary: UserDictionary,
        cloudCorrection: CloudCorrectionService
    ) {
        self.modelManager = modelManager
        self.delivery = DictationDelivery(
            history: history,
            dictionary: dictionary,
            cloudCorrection: cloudCorrection
        )
        recorder.onInterrupted = { [weak self] in
            // Input device vanished mid-recording: transcribe what we have.
            self?.finishRecording()
        }
    }

    /// Registers the global hotkeys. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        hotkeys.register(
            onPushToTalkDown: { [weak self] in self?.pushToTalkDown() },
            onPushToTalkUp: { [weak self] in self?.pushToTalkUp() },
            onToggle: { [weak self] in self?.toggle() },
            onNoteDown: { [weak self] in self?.beginRecording(trigger: .notePushToTalk) },
            onNoteUp: { [weak self] in
                guard let self, self.session.activeTrigger == .notePushToTalk else { return }
                self.finishRecording()
            },
            onNoteToggle: { [weak self] in self?.toggle(trigger: .noteToggle) }
        )
        modifierHotkeys.onPushToTalkDown = { [weak self] in self?.pushToTalkDown() }
        modifierHotkeys.onPushToTalkUp = { [weak self] in self?.pushToTalkUp() }
        modifierHotkeys.onPushToTalkCancel = { [weak self] in self?.cancelPushToTalk() }
        modifierHotkeys.onToggle = { [weak self] in self?.toggle() }
        modifierHotkeys.start()
    }

    // MARK: Hotkey handlers

    private func pushToTalkDown() {
        // While capture or delivery is busy, a new press cannot start another recording;
        // because no session is attributed to push-to-talk, its key-up will be ignored as well.
        beginRecording(trigger: .pushToTalk)
    }

    private func pushToTalkUp() {
        guard session.state == .recording, session.activeTrigger == .pushToTalk else { return }
        finishRecording()
    }

    /// The push-to-talk modifier turned out to be part of a key combo: discard, don't transcribe.
    private func cancelPushToTalk() {
        guard session.state == .recording, session.activeTrigger == .pushToTalk else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.stop()
        session.cancelRecording()
        state = session.state
    }

    private func toggle(trigger: CaptureTrigger = .toggle) {
        switch session.state {
        case .recording:
            // Only the toggle shortcut may end a toggle session; while push-to-talk is held the
            // press is ignored (the user is already in a hold-to-talk gesture).
            if session.activeTrigger == trigger { finishRecording() }
        default:
            beginRecording(trigger: trigger)
        }
    }

    // MARK: Recording

    private func beginRecording(trigger: CaptureTrigger) {
        guard !isQuitting, session.canBeginRecording(onBusy: { self.playSound("Basso") }),
              !isRequestingMicrophone else { return }

        guard modelManager.isReady else {
            showError("No model ready — pick and download one in Settings")
            return
        }

        if Permissions.microphoneUndetermined {
            requestMicrophoneThenPrompt()
            return
        }
        guard Permissions.microphoneGranted else {
            showError("Microphone access denied — enable it in System Settings")
            return
        }

        do {
            try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }

        errorClearTask?.cancel()
        let app = NSWorkspace.shared.frontmostApplication
        recordingAppBundleID = app?.bundleIdentifier
        recordingAppName = app?.localizedName
        session.beginRecording(trigger: trigger)
        state = session.state
        playSound("Tink")

        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
    }

    /// First use: the system prompt steals focus, so by the time it's answered the shortcut has
    /// long been released. Don't start recording behind the user's back; ask them to press again.
    private func requestMicrophoneThenPrompt() {
        isRequestingMicrophone = true
        Task { [weak self] in
            let granted = await Permissions.requestMicrophone()
            guard let self else { return }
            self.isRequestingMicrophone = false
            if granted {
                self.showError("Microphone enabled — press the shortcut again")
            } else {
                self.showError("Microphone access denied — enable it in System Settings")
            }
        }
    }

    private func finishRecording() {
        guard session.state == .recording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let destination = session.activeTrigger?.destination ?? .dictation
        let samples = recorder.stop()
        playSound("Pop")

        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        guard duration >= Self.minimumDuration else {
            session.discardShortRecording() // accidental tap
            state = session.state
            return
        }

        _ = session.beginTranscribing()
        state = session.state
        transcriptionTask = Task { [weak self] in
            defer { self?.transcriptionTask = nil }
            await self?.transcribeAndInsert(samples, durationSeconds: duration, destination: destination)
        }
    }

    // MARK: Transcription & Delivery

    private func transcribeAndInsert(_ samples: [Float], durationSeconds: Double, destination: CaptureDestination) async {
        let modelID = modelManager.selectedModelID
        let rawText: String
        do {
            rawText = try await modelManager.transcribe(samples)
        } catch {
            showError("Transcription failed: \(error.localizedDescription)")
            return
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !DictationDelivery.isNonSpeechMarker(trimmed) else {
            showError("No speech detected")
            return
        }

        let target = NSWorkspace.shared.frontmostApplication
        let appBundleID = destination == .note ? recordingAppBundleID : target?.bundleIdentifier
        let appName = destination == .note ? recordingAppName : target?.localizedName
        let keepOnClipboard = UserDefaults.standard.bool(forKey: TextInserter.keepOnClipboardKey)

        do {
            _ = try await delivery.deliver(
                rawText: rawText,
                appBundleID: appBundleID,
                appName: appName,
                modelID: modelID,
                durationSeconds: durationSeconds,
                destination: destination,
                willCorrect: {
                    self.session.beginCorrecting()
                    self.state = self.session.state
                }
            ) { text in
                guard !self.isQuitting else { return }
                try await TextInserter.insert(text, keepOnClipboard: keepOnClipboard,
                                              targetProcessID: target?.processIdentifier)
            }
            session.finishTranscribing()
            state = session.state
        } catch {
            if case TextInserter.InsertError.accessibilityNotGranted = error,
               !promptedAccessibilityThisLaunch {
                promptedAccessibilityThisLaunch = true
                Permissions.promptAccessibility()
            }
            showError(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func showError(_ message: String) {
        errorClearTask?.cancel()
        session.setError(message)
        state = session.state
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorDisplayDuration)
            guard !Task.isCancelled, let self, case .error = self.session.state else { return }
            self.session.clearErrorIfShowing()
            self.state = self.session.state
        }
    }

    private func playSound(_ name: NSSound.Name) {
        guard UserDefaults.standard.object(forKey: "playFeedbackSounds") as? Bool ?? true else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.stop()
        sound.play()
    }
}
