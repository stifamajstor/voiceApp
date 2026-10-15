import Combine
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var updater: Updater
    @AppStorage(ModifierKey.Action.pushToTalk.defaultsKey) private var pushToTalkModifier = ModifierKey.rightOption.rawValue
    @AppStorage(ModifierKey.Action.toggleToTalk.defaultsKey) private var toggleModifier = ModifierKey.none.rawValue

    @AppStorage(TextInserter.keepOnClipboardKey) private var keepOnClipboard = false
    @AppStorage("playFeedbackSounds") private var playFeedbackSounds = true

    var body: some View {
        Form {
            Section {
                ForEach(TranscriptionModel.all) { model in
                    ModelRow(model: model)
                }
                if let error = modelManager.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                }
            } header: {
                SectionTitle("Model")
            } footer: {
                Text("Models are stored in ~/Library/Application Support/VoiceApp/models. The first load of a model can take a minute while Core ML optimizes it for this Mac.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Section {
                Picker("Spoken language", selection: $modelManager.languageCode) {
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                if let model = modelManager.selectedModel, model.engine == .parakeet {
                    Text("\(model.displayName) detects the language automatically; this setting is ignored.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else if let model = modelManager.selectedModel, !model.isMultilingual {
                    Text("\(model.displayName) is English-only; this setting is ignored.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } header: {
                SectionTitle("Language")
            }

            Section {
                Picker("Push to talk — hold key", selection: $pushToTalkModifier) {
                    ForEach(ModifierKey.allCases) { Text($0.title).tag($0.rawValue) }
                }
                KeyboardShortcuts.Recorder("Push to talk — key combo", name: .pushToTalk)
                Picker("Toggle to talk — tap key", selection: $toggleModifier) {
                    ForEach(ModifierKey.allCases) { Text($0.title).tag($0.rawValue) }
                }
                KeyboardShortcuts.Recorder("Toggle to talk — key combo", name: .toggleToTalk)
                if pushToTalkModifier == toggleModifier, pushToTalkModifier != ModifierKey.none.rawValue {
                    Label("Both use the same key; it will act as push to talk.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                }
            } header: {
                SectionTitle("Shortcuts")
            } footer: {
                Text("Push to talk records while held. Toggle starts on the first press and stops on the second. A single modifier key (hold/tap key) needs Accessibility permission and is ignored when combined with other keys, so typing ⌥-characters still works. Key combos work without it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Section {
                Toggle("Keep transcript on clipboard after pasting", isOn: $keepOnClipboard)
                Toggle("Play start/stop sounds", isOn: $playFeedbackSounds)
            } header: {
                SectionTitle("Behavior")
            } footer: {
                Text("By default, VoiceApp restores your previous clipboard after pasting.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.switch)

            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .toggleStyle(.switch)
                HStack {
                    Text("Version \(updater.currentVersion)")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .buttonStyle(NeonButtonStyle())
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                SectionTitle("Updates")
            } footer: {
                Text("New versions are downloaded from the project's GitHub releases and installed when VoiceApp next quits or relaunches.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            PermissionsSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.neon)
        .preferredColorScheme(.dark)
        .frame(width: 540, height: 640)
    }
}

// MARK: - Model row

private struct ModelRow: View {
    @EnvironmentObject private var modelManager: ModelManager
    let model: TranscriptionModel

    private var isSelected: Bool { modelManager.selectedModelID == model.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Theme.neon : Theme.textSecondary)
                .neonGlow(isSelected, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.body.weight(isSelected ? .semibold : .regular))
                Text("\(model.approximateSize) · \(model.notes)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if isSelected, case .failed(let message) = modelManager.loadState {
                    Text("Failed to load: \(message)")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(3)
                }
            }

            Spacer()
            controls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        switch modelManager.downloadState(for: model.id) {
        case .notDownloaded:
            Button("Download") { modelManager.download(model.id) }
                .buttonStyle(NeonButtonStyle(prominent: true))

        case .downloading(let progress):
            ProgressView(value: progress)
                .tint(Theme.neon)
                .frame(width: 110)
            Text("\(Int(progress * 100))%")
                .monospacedDigit()
                .font(.caption)
                .frame(width: 34, alignment: .trailing)
            Button {
                modelManager.cancelDownload(model.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Cancel download")

        case .downloaded:
            if isSelected {
                selectedStatus
            } else {
                Button("Use") { modelManager.selectedModelID = model.id }
                    .buttonStyle(NeonButtonStyle(prominent: true))
            }
            Button(role: .destructive) {
                modelManager.delete(model.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.danger)
            .help("Delete downloaded model")

        case .deleting:
            ProgressView().controlSize(.small).tint(Theme.neon)
            Text("Deleting…").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var selectedStatus: some View {
        switch modelManager.loadState {
        case .loading:
            ProgressView().controlSize(.small).tint(Theme.neon)
            Text("Loading…").font(.caption).foregroundStyle(Theme.textSecondary)
        case .loaded:
            Text("Active").font(.caption).foregroundStyle(Theme.neon)
        case .failed:
            Button("Retry") { modelManager.reloadSelectedModel() }
                .buttonStyle(NeonButtonStyle())
        case .unloaded:
            Button("Load") { modelManager.reloadSelectedModel() }
                .buttonStyle(NeonButtonStyle())
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @State private var microphoneGranted = Permissions.microphoneGranted
    @State private var accessibilityGranted = Permissions.accessibilityGranted

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            PermissionRow(
                title: "Microphone",
                detail: "Needed to record your voice.",
                granted: microphoneGranted
            ) {
                Button("Grant") {
                    Task {
                        let granted = await Permissions.requestMicrophone()
                        if !granted { Permissions.openMicrophoneSettings() }
                        refresh()
                    }
                }
                Button("Open Settings") { Permissions.openMicrophoneSettings() }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Needed to paste text and to use a single modifier key as shortcut.",
                granted: accessibilityGranted
            ) {
                Button("Grant") { Permissions.promptAccessibility() }
                Button("Open Settings") { Permissions.openAccessibilitySettings() }
            }
        } header: {
            SectionTitle("Permissions")
        } footer: {
            Text("After rebuilding the app you may need to remove and re-add it under Accessibility.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        microphoneGranted = Permissions.microphoneGranted
        accessibilityGranted = Permissions.accessibilityGranted
    }
}

private struct PermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(granted ? Theme.neon : Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(granted ? "Granted" : detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !granted {
                actions()
                    .buttonStyle(NeonButtonStyle())
            }
        }
    }
}
