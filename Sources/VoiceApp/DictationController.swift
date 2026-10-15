import AppKit
import Foundation

/// Orchestrates hotkey -> record -> transcribe -> paste.
///
/// State machine: idle -> recording -> transcribing -> idle, with `error(message)` as a transient
/// state that clears itself after a few seconds. Hotkeys are ignored while transcribing.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    /// A finished transcription, kept in memory only so it can be copied again from the menu.
    struct Transcript: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    @Published private(set) var state: State = .idle
    /// Newest first, capped at `historyLimit`. Not persisted.
    @Published private(set) var recentTranscripts: [Transcript] = []

    static let historyLimit = 5

    /// Recordings shorter than this are treated as accidental taps and dropped.
    static let minimumDuration: TimeInterval = 0.3
    /// Safety net for a lost key-up / forgotten toggle session.
    static let maximumDuration: TimeInterval = 300
    private static let errorDisplayDuration: Duration = .seconds(3)

    /// Which shortcut owns the running recording. A key-up of the *other* shortcut must not end it.
    private enum Trigger { case pushToTalk, toggle }

    private let modelManager: ModelManager
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private let modifierHotkeys = ModifierHotkeyMonitor()

    private var started = false
    private var activeTrigger: Trigger?
    private var isRequestingMicrophone = false
    private var errorClearTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var promptedAccessibilityThisLaunch = false

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
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
            onToggle: { [weak self] in self?.toggle() }
        )
        modifierHotkeys.onPushToTalkDown = { [weak self] in self?.pushToTalkDown() }
        modifierHotkeys.onPushToTalkUp = { [weak self] in self?.pushToTalkUp() }
        modifierHotkeys.onPushToTalkCancel = { [weak self] in self?.cancelPushToTalk() }
        modifierHotkeys.onToggle = { [weak self] in self?.toggle() }
        modifierHotkeys.start()
    }

    // MARK: Hotkey handlers

    private func pushToTalkDown() {
        // While a toggle session is running (or we're busy) the press is ignored; because no
        // session is attributed to push-to-talk, its key-up will be ignored as well.
        beginRecording(trigger: .pushToTalk)
    }

    private func pushToTalkUp() {
        guard state == .recording, activeTrigger == .pushToTalk else { return }
        finishRecording()
    }

    /// The push-to-talk modifier turned out to be part of a key combo: discard, don't transcribe.
    private func cancelPushToTalk() {
        guard state == .recording, activeTrigger == .pushToTalk else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        activeTrigger = nil
        recorder.stop()
        state = .idle
    }

    private func toggle() {
        switch state {
        case .recording:
            // Only the toggle shortcut may end a toggle session; while push-to-talk is held the
            // press is ignored (the user is already in a hold-to-talk gesture).
            if activeTrigger == .toggle { finishRecording() }
        default:
            beginRecording(trigger: .toggle)
        }
    }

    // MARK: Recording

    private func beginRecording(trigger: Trigger) {
        switch state {
        case .idle, .error: break
        case .recording, .transcribing: return
        }
        guard !isRequestingMicrophone else { return }

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
        activeTrigger = trigger
        state = .recording
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
        guard state == .recording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        activeTrigger = nil

        let samples = recorder.stop()
        playSound("Pop")

        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        guard duration >= Self.minimumDuration else {
            state = .idle // accidental tap
            return
        }

        state = .transcribing
        transcriptionTask = Task { [weak self] in
            await self?.transcribeAndInsert(samples)
        }
    }

    // MARK: Transcription

    private func transcribeAndInsert(_ samples: [Float]) async {
        let text: String
        do {
            text = try await modelManager.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            showError("Transcription failed: \(error.localizedDescription)")
            return
        }

        guard !text.isEmpty, !Self.isNonSpeechMarker(text) else {
            showError("No speech detected")
            return
        }

        recentTranscripts.insert(Transcript(text: text, date: .now), at: 0)
        if recentTranscripts.count > Self.historyLimit {
            recentTranscripts.removeLast(recentTranscripts.count - Self.historyLimit)
        }

        do {
            let keepOnClipboard = UserDefaults.standard.bool(forKey: TextInserter.keepOnClipboardKey)
            try await TextInserter.insert(text, keepOnClipboard: keepOnClipboard)
            state = .idle
        } catch {
            if case TextInserter.InsertError.accessibilityNotGranted = error,
               !promptedAccessibilityThisLaunch {
                promptedAccessibilityThisLaunch = true
                Permissions.promptAccessibility()
            }
            showError(error.localizedDescription)
        }
    }

    /// Whisper emits things like "[BLANK_AUDIO]" or "(silence)" for empty input.
    private static func isNonSpeechMarker(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        return (first == "[" && last == "]") || (first == "(" && last == ")")
    }

    // MARK: History

    func copyToClipboard(_ transcript: Transcript) {
        TextInserter.copy(transcript.text)
    }

    func clearHistory() {
        recentTranscripts.removeAll()
    }

    // MARK: Helpers

    private func showError(_ message: String) {
        errorClearTask?.cancel()
        state = .error(message)
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorDisplayDuration)
            guard !Task.isCancelled, let self, case .error = self.state else { return }
            self.state = .idle
        }
    }

    private func playSound(_ name: NSSound.Name) {
        guard UserDefaults.standard.object(forKey: "playFeedbackSounds") as? Bool ?? true else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.stop()
        sound.play()
    }
}
