import AppKit
import SwiftUI
import VoiceAppCore

@main
struct VoiceApp: App {
    @StateObject private var modelManager: ModelManager
    @StateObject private var dictation: DictationController
    @StateObject private var history: DictationHistory
    @StateObject private var historyWindow: HistoryWindowController
    @StateObject private var updater = Updater()

    init() {
        ModifierKey.registerDefaults()
        let modelManager = ModelManager()
        let history = DictationHistory()
        let dictation = DictationController(modelManager: modelManager, history: history)
        _history = StateObject(wrappedValue: history)
        _historyWindow = StateObject(wrappedValue: HistoryWindowController(history: history))
        history.start()
        _modelManager = StateObject(wrappedValue: modelManager)
        _dictation = StateObject(wrappedValue: dictation)
        // Register hotkeys once the app has finished launching and the run loop is up.
        Task { @MainActor in dictation.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openHistory: historyWindow.show)
                .environmentObject(modelManager)
                .environmentObject(dictation)
                .environmentObject(history)
                .environmentObject(updater)
        } label: {
            MenuBarIcon(dictation: dictation, modelManager: modelManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(history)
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

    var body: some View {
        switch dictation.state {
        case .recording:
            Image(nsImage: Self.recordingImage)
        case .transcribing:
            Image(nsImage: Self.transcribingImage)
        case .error:
            Image(systemName: "exclamationmark.triangle")
        case .idle:
            if modelManager.loadState == .loading {
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
