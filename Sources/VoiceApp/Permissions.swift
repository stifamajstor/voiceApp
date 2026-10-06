import AppKit
import ApplicationServices
import AVFoundation

/// Thin wrappers around the two TCC permissions the app needs.
///
/// - Microphone: required to record.
/// - Accessibility: required to synthesize the ⌘V key press that pastes the transcript.
///   Also needed for single-modifier shortcuts (NSEvent global monitors); Carbon key combos
///   registered through KeyboardShortcuts do not need it.
enum Permissions {
    // MARK: Microphone

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    /// True until the user has answered the system prompt once.
    static var microphoneUndetermined: Bool {
        microphoneStatus == .notDetermined
    }

    /// Shows the system prompt if the status is undetermined; otherwise returns the current state.
    static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false // denied / restricted: the system will not prompt again
        }
    }

    // MARK: Accessibility

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system "VoiceApp would like to control this computer" prompt, which offers a
    /// button to open System Settings. Does nothing visible if access was already granted.
    static func promptAccessibility() {
        // Literal value of kAXTrustedCheckOptionPrompt (avoids touching the C global var).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: System Settings deep links

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
