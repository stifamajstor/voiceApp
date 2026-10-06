import AppKit
import KeyboardShortcuts
import SwiftUI

/// Content of the menu bar popover: status, quick model picker, shortcuts, Settings and Quit.
struct MenuBarView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            modelSection
            shortcutsSection
            Divider()
            HStack {
                OpenSettingsButton()
                Spacer()
                Button("Quit VoiceApp") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: dictationSymbol)
                .font(.title2)
                .foregroundStyle(dictationColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(dictationTitle).font(.headline).lineLimit(2)
                Text(modelManager.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        let downloaded = modelManager.downloadedModels
        if downloaded.isEmpty {
            Text("No model downloaded yet. Open Settings to download one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: $modelManager.selectedModelID) {
                ForEach(downloaded) { model in
                    Text(model.displayName).tag(model.id)
                }
                // Keep the picker valid if the selected model isn't downloaded.
                if !downloaded.contains(where: { $0.id == modelManager.selectedModelID }) {
                    Text(modelManager.selectedModel?.displayName ?? "None")
                        .tag(modelManager.selectedModelID)
                }
            }
            .disabled(modelManager.loadState == .loading)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            shortcutRow("Push to talk", name: .pushToTalk, modifier: .pushToTalk)
            shortcutRow("Toggle", name: .toggleToTalk, modifier: .toggleToTalk)
        }
        .font(.caption)
    }

    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name, modifier: ModifierKey.Action) -> some View {
        let key = ModifierKey.current(for: modifier)
        let triggers = [key == .none ? nil : key.title, KeyboardShortcuts.getShortcut(for: name)?.description].compactMap { $0 }
        return HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(triggers.isEmpty ? "Not set" : triggers.joined(separator: " or "))
                .monospaced()
        }
    }

    // MARK: - Dictation state presentation

    private var dictationTitle: String {
        switch dictation.state {
        case .idle: return modelManager.isReady ? "Ready to dictate" : "Not ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .error(let message): return message
        }
    }

    private var dictationSymbol: String {
        switch dictation.state {
        case .idle: return modelManager.isReady ? "mic" : "mic.slash"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var dictationColor: Color {
        switch dictation.state {
        case .idle: return modelManager.isReady ? .primary : .secondary
        case .recording: return .red
        case .transcribing: return .accentColor
        case .error: return .orange
        }
    }
}

/// Opens the Settings scene and brings it to the front. The app is `LSUIElement`, so it has to
/// be activated explicitly or the window would open behind the frontmost app.
struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openSettings()
            // The window is created asynchronously; order it front once it exists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let settingsWindow = NSApp.windows.first {
                    $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
                } ?? NSApp.windows.first { $0.isVisible && $0.level == .normal && $0.canBecomeKey }
                settingsWindow?.makeKeyAndOrderFront(nil)
                settingsWindow?.orderFrontRegardless()
            }
        }
        .keyboardShortcut(",")
    }
}
