import AppKit
import SwiftUI
import VoiceAppCore
import UserNotifications

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var modelManager: ModelManager
    @StateObject private var dictation: DictationController
    @StateObject private var history: DictationHistory
    @StateObject private var dictionary: UserDictionary
    @StateObject private var notesWindow: NotesWindowController
    @StateObject private var cloudCorrection: CloudCorrectionService
    @StateObject private var historyWindow: HistoryWindowController
    @StateObject private var termination: HistoryTermination
    @StateObject private var updater = Updater()

    init() {
        ModifierKey.registerDefaults()
        let repository = SQLiteHistoryRepository()
        let modelManager = ModelManager()
        let history = DictationHistory(repository: repository)
        let dictionary = UserDictionary(repository: repository)
        let cloudCorrection = CloudCorrectionService()
        let dictation = DictationController(
            modelManager: modelManager,
            history: history,
            dictionary: dictionary,
            cloudCorrection: cloudCorrection
        )
        _history = StateObject(wrappedValue: history)
        _dictionary = StateObject(wrappedValue: dictionary)
        _cloudCorrection = StateObject(wrappedValue: cloudCorrection)
        let historyWindow = HistoryWindowController(history: history)
        _historyWindow = StateObject(wrappedValue: historyWindow)
        let notesWindow = NotesWindowController(history: history)
        _notesWindow = StateObject(wrappedValue: notesWindow)
        _modelManager = StateObject(wrappedValue: modelManager)
        _dictation = StateObject(wrappedValue: dictation)
        let termination = HistoryTermination(history: history,
            pendingTranscription: { dictation.transcriptionTask },
            prepareToQuit: { dictation.isQuitting = true },
            quitCancelled: { dictation.isQuitting = false }, showHistory: {
            if history.noteDeleteError != nil { notesWindow.show() } else { historyWindow.show() }
        })
        _termination = StateObject(wrappedValue: termination)
        appDelegate.termination = termination
        appDelegate.notesWindow = notesWindow
        appDelegate.history = history
        UNUserNotificationCenter.current().delegate = appDelegate
        history.start()
        dictionary.start()
        // Register hotkeys once the app has finished launching and the run loop is up.
        Task { @MainActor in dictation.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openHistory: historyWindow.show, openNotes: notesWindow.show, quit: appDelegate.requestMenuQuit)
                .environmentObject(modelManager)
                .environmentObject(dictation)
                .environmentObject(history)
                .environmentObject(updater)
                .environmentObject(termination)
        } label: {
            MenuBarIcon(dictation: dictation, modelManager: modelManager, history: history)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(history)
                .environmentObject(dictionary)
                .environmentObject(cloudCorrection)
                .environmentObject(modelManager)
                .environmentObject(updater)
        }
    }
}

/// Menu bar glyph reflecting the dictation state. Observes the objects directly so the
/// label re-renders reliably.
struct MenuBarIcon: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var history: DictationHistory

    var body: some View {
        switch dictation.state {
        case .recording:
            Image(nsImage: Self.recordingImage)
        case .correcting:
            Image(systemName: "text.badge.checkmark").help("Correcting…")
        case .transcribing:
            Image(nsImage: Self.transcribingImage)
        case .error:
            Image(systemName: "exclamationmark.triangle")
        case .idle:
            if history.noteFeedback != nil {
                Image(systemName: "checkmark.circle").help("Note saved")
            } else if modelManager.loadState == .loading {
                Image(systemName: "ellipsis.circle")
            } else {
                Image(systemName: modelManager.isReady ? "mic" : "mic.slash")
            }
        }
    }

    /// NSColor equivalent of Theme.neon (#39FF64).
    private static let neonGreen = NSColor(srgbRed: 0.224, green: 1.0, blue: 0.392, alpha: 1)

    /// Menu bar labels are rendered as templates (monochrome), so active colored glyphs
    /// need non-template images with palette symbol configurations.
    private static func coloredImage(systemSymbolName: String, accessibilityDescription: String?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [neonGreen]))
        let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }

    private static let recordingImage: NSImage = coloredImage(
        systemSymbolName: "mic.fill",
        accessibilityDescription: "Recording"
    )

    private static let transcribingImage: NSImage = coloredImage(
        systemSymbolName: "waveform",
        accessibilityDescription: "Transcribing"
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var notesWindow: NotesWindowController?
    var history: DictationHistory?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        if let id = NoteNotification.noteID(for: response.notification.request.identifier) {
            await history?.reminderDidAlert(requestID: response.notification.request.identifier).value
            await MainActor.run { self.notesWindow?.reveal(noteID: id) }
        } else if response.notification.request.identifier == NoteNotification.summaryIdentifier {
            await MainActor.run { self.notesWindow?.show() }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if NoteNotification.noteID(for: notification.request.identifier) != nil {
            await history?.reminderDidAlert(requestID: notification.request.identifier).value
        }
        return [.banner, .list, .sound]
    }
    var termination: HistoryTermination?

    func requestMenuQuit() {
        // Let the SwiftUI button action return so the pending menu can repaint.
        // Default mode only: after a cancelled quit AppKit is still inside its first terminate call,
        // running a modal-panel loop. A .common-mode perform would fire there, and a second
        // terminate skips the delegate and exits with queued saves unwritten.
        perform(#selector(quitFromMenu), with: nil, afterDelay: 0, inModes: [.default])
    }

    @objc private func quitFromMenu() {
        termination?.requestQuit { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Call NSApp.terminate from an AppKit event, never a main-actor task or main-queue block:
        // AppKit would wait there and prevent the queue-draining task from replying.
        let mayQuit = termination?.requestTermination { success in
            sender.reply(toApplicationShouldTerminate: success)
        } ?? true
        return mayQuit ? .terminateNow : .terminateLater
    }
}
