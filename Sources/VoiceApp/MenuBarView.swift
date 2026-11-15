import AppKit
import KeyboardShortcuts
import SwiftUI
import VoiceAppCore

/// Content of the menu bar popover: status, quick model picker, recent transcripts, shortcuts,
/// Settings and Quit.
struct MenuBarView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var history: DictationHistory
    let openHistory: () -> Void
    @AppStorage(TextInserter.keepOnClipboardKey) private var keepOnClipboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modelSection
            recentSection
            shortcutsSection
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.neon)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(dictationColor.opacity(0.12))
                Circle().strokeBorder(dictationColor.opacity(0.55), lineWidth: 1)
                Image(systemName: dictationSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(dictationColor)
                    .symbolEffect(.pulse, isActive: isBusy)
            }
            .frame(width: 40, height: 40)
            .shadow(color: dictationColor.opacity(isBusy ? 0.7 : (modelManager.isReady ? 0.3 : 0)), radius: isBusy ? 10 : 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(dictationTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(modelManager.statusDescription)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: dictation.state)
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        let downloaded = modelManager.downloadedModels
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Model")
            if downloaded.isEmpty {
                Text("No model downloaded yet. Open Settings to download one.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
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
                .labelsHidden()
                .disabled(modelManager.loadState == .loading)
            }
        }
        .themeCard()
    }

    // MARK: - Recent transcripts

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Recent")
                Spacer()
                if let last = history.recent.first {
                    Button {
                        TextInserter.copy(last.text)
                    } label: {
                        Label("Copy last", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(NeonButtonStyle())
                    .keyboardShortcut("c")
                    .help("Copy the latest transcript to the clipboard (⌘C)")
                }
            }

            if history.recent.isEmpty {
                Text("Your latest transcripts appear here, ready to copy again.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(history.recent) { transcript in
                        TranscriptRow(transcript: transcript) {
                            TextInserter.copy(transcript.text)
                        }
                    }
                }
            }

            Text(history.savingDisclosure)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Toggle("Keep on clipboard after paste", isOn: $keepOnClipboard)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            HStack {
                Button("History…", action: openHistory)
                    .buttonStyle(NeonButtonStyle())
                Spacer()
                if !history.recent.isEmpty {
                    Button("Clear recent") { history.clearRecent() }
                        .help("Hide this recent list. Stored history is kept.")
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .themeCard()
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Shortcuts")
            shortcutRow("Push to talk", name: .pushToTalk, modifier: .pushToTalk)
            shortcutRow("Toggle", name: .toggleToTalk, modifier: .toggleToTalk)
        }
        .font(.caption)
        .themeCard()
    }

    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name, modifier: ModifierKey.Action) -> some View {
        let key = ModifierKey.current(for: modifier)
        let triggers = [key == .none ? nil : key.title, KeyboardShortcuts.getShortcut(for: name)?.description].compactMap { $0 }
        return HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            if triggers.isEmpty {
                Text("Not set").foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(triggers, id: \.self) { trigger in
                    Text(trigger)
                        .monospaced()
                        .foregroundStyle(Theme.neon)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.neon.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.neon.opacity(0.25)))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            OpenSettingsButton()
            Button {
                updater.checkForUpdates()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(!updater.canCheckForUpdates)
            .help("Check for updates (v\(updater.currentVersion))")
            Spacer()
            Button("Quit VoiceApp") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(NeonButtonStyle())
    }

    // MARK: - Dictation state presentation

    private var isBusy: Bool {
        dictation.state == .recording || dictation.state == .transcribing
    }

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
        case .idle: return modelManager.isReady ? Theme.neon : Theme.textSecondary
        case .recording, .transcribing: return Theme.neon
        case .error: return Theme.warning
        }
    }
}

/// One recent transcript; clicking anywhere on it copies the text.
private struct TranscriptRow: View {
    let transcript: DictationHistory.Recent
    let onCopy: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var copyCount = 0

    var body: some View {
        Button {
            onCopy()
            copied = true
            copyCount += 1
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transcript.text)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Theme.textPrimary)
                    Text(transcript.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.neon)
                    .opacity(hovering || copied ? 1 : 0.35)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(transcript.text)
        // Restarts on every click, so an older tap can't clear the checkmark of a newer one.
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
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
