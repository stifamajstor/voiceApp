import AppKit
import SwiftUI

@main
struct VoiceApp: App {
    @StateObject private var modelManager: ModelManager
    @StateObject private var dictation: DictationController

    init() {
        ModifierKey.registerDefaults()
        let modelManager = ModelManager()
        let dictation = DictationController(modelManager: modelManager)
        _modelManager = StateObject(wrappedValue: modelManager)
        _dictation = StateObject(wrappedValue: dictation)
        // Register hotkeys once the app has finished launching and the run loop is up.
        Task { @MainActor in dictation.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(modelManager)
                .environmentObject(dictation)
        } label: {
            MenuBarIcon(dictation: dictation, modelManager: modelManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(modelManager)
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
            Image(systemName: "waveform")
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

    /// Menu bar labels are rendered as templates (monochrome), so the red recording glyph
    /// needs a non-template image.
    private static let recordingImage: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}
