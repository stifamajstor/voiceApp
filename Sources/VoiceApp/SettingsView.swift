import Combine
import KeyboardShortcuts
import SwiftUI
import VoiceAppCore

struct SettingsView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var history: DictationHistory
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
                ValidatedShortcutRecorder("Push to talk — key combo", name: .pushToTalk)
                Picker("Toggle to talk — tap key", selection: $toggleModifier) {
                    ForEach(ModifierKey.allCases) { Text($0.title).tag($0.rawValue) }
                }
                ValidatedShortcutRecorder("Toggle to talk — key combo", name: .toggleToTalk)
                ValidatedShortcutRecorder("Note — push to talk", name: .notePushToTalk)
                ValidatedShortcutRecorder("Note — toggle", name: .noteToggle)
                Text("Note shortcuts start unbound. Notes are always saved locally and never pasted.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
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
                Toggle("Save dictation history", isOn: $history.saveEnabled)
                if history.isOpening {
                    Label("Opening dictation history…", systemImage: "hourglass")
                        .foregroundStyle(Theme.textSecondary)
                }
                if let error = history.storeError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
                if let error = history.saveError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            } header: {
                SectionTitle("Behavior")
            } footer: {
                Text("By default, VoiceApp restores your previous clipboard after pasting. History is saved locally; turning it off keeps existing records. Open History from the menu to search or delete them.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.switch)

            DictionarySection()

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

/// The recorder persists before calling onChange; restore the last accepted value on conflict.
private struct ValidatedShortcutRecorder: View {
    private static let names: [KeyboardShortcuts.Name] = [.pushToTalk, .toggleToTalk, .notePushToTalk, .noteToggle]
    let title: String
    let name: KeyboardShortcuts.Name
    @State private var accepted: KeyboardShortcuts.Shortcut?
    @State private var message: String?

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
        _accepted = State(initialValue: KeyboardShortcuts.getShortcut(for: name))
    }

    var body: some View {
        KeyboardShortcuts.Recorder(title, name: name) { candidate in
            let result = ShortcutValidation.resolve(candidate: candidate, previous: accepted,
                others: Self.names.filter { $0 != name }.map { KeyboardShortcuts.getShortcut(for: $0) })
            message = result.message
            accepted = result.value
            if result.message != nil { KeyboardShortcuts.setShortcut(result.value, for: name) }
        }
        if let message { Text(message).font(.callout).foregroundStyle(Theme.warning) }
    }
}

// MARK: - Dictionary

private struct DictionarySection: View {
    private enum EditorMode: Identifiable {
        case add
        case edit(DictionaryTerm)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let term): return term.id.uuidString
            }
        }
    }

    @EnvironmentObject private var dictionary: UserDictionary
    @State private var searchQuery = ""
    @State private var editorMode: EditorMode?
    @State private var termPendingDeletion: DictionaryTerm?
    @State private var isDeleteConfirmationPresented = false
    @State private var deleteError: String?

    private static let searchThreshold = 8

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTerms: [DictionaryTerm] {
        guard !trimmedQuery.isEmpty else { return dictionary.terms }
        return dictionary.terms.filter { term in
            term.text.localizedStandardContains(trimmedQuery) ||
            term.aliases.contains { $0.localizedStandardContains(trimmedQuery) }
        }
    }

    private var summaryText: String {
        if dictionary.isLoading { return "Loading dictionary…" }
        if dictionary.terms.isEmpty { return "No terms yet" }
        if !trimmedQuery.isEmpty {
            return "\(filteredTerms.count) of \(dictionary.terms.count) terms"
        }
        let count = dictionary.terms.count
        return "\(count) \(count == 1 ? "term" : "terms")"
    }

    var body: some View {
        Section {
            HStack {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Add Term…") {
                    deleteError = nil
                    editorMode = .add
                }
                .buttonStyle(NeonButtonStyle(prominent: true))
                .disabled(dictionary.isLoading || dictionary.storeError != nil)
            }

            if let error = dictionary.storeError ?? deleteError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .font(.callout)
            }

            if dictionary.terms.count >= Self.searchThreshold || !searchQuery.isEmpty {
                TextField("Search terms or aliases", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            if !dictionary.isLoading && dictionary.storeError == nil && dictionary.terms.isEmpty {
                Text("Add spellings and spoken aliases (for example, \"Mac\" with aliases \"MEC, Meg\"). VoiceApp replaces aliases before pasting.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else if filteredTerms.isEmpty && !dictionary.terms.isEmpty {
                Text("No matching terms.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } else if filteredTerms.count <= 6 {
                ForEach(filteredTerms) { term in
                    termRow(term)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredTerms.enumerated()), id: \.element.id) { index, term in
                            if index > 0 { Divider() }
                            termRow(term)
                        }
                    }
                }
                .frame(height: 220)
            }
        } header: {
            SectionTitle("Dictionary")
        } footer: {
            Text("Terms and aliases match whole words case-insensitively before pasting and are stored locally.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .sheet(item: $editorMode) { mode in
            TermEditorSheet(mode: mode)
                .environmentObject(dictionary)
        }
        .alert(
            "Delete \"\(termPendingDeletion?.text ?? "")\"?",
            isPresented: $isDeleteConfirmationPresented,
            presenting: termPendingDeletion
        ) { term in
            Button("Cancel", role: .cancel) {
                termPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                termPendingDeletion = nil
                Task {
                    do {
                        try await dictionary.deleteTerm(id: term.id)
                    } catch {
                        deleteError = dictionary.errorMessage(for: error)
                    }
                }
            }
        } message: { term in
            if term.aliases.isEmpty {
                Text("This removes \"\(term.text)\" from your dictionary.")
            } else {
                Text("This removes \"\(term.text)\" and its aliases (\(term.aliases.joined(separator: ", "))) from your dictionary.")
            }
        }
    }

    private func termRow(_ term: DictionaryTerm) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                if !term.aliases.isEmpty {
                    Text(term.aliases.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Button("Edit") {
                deleteError = nil
                editorMode = .edit(term)
            }
            .buttonStyle(NeonButtonStyle())
            .accessibilityLabel("Edit \(term.text)")
            Button(role: .destructive) {
                deleteError = nil
                termPendingDeletion = term
                isDeleteConfirmationPresented = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.danger)
            .help("Delete term")
            .accessibilityLabel("Delete \(term.text)")
        }
        .padding(.vertical, 4)
    }

    private struct TermEditorSheet: View {
        let mode: EditorMode
        @EnvironmentObject private var dictionary: UserDictionary
        @Environment(\.dismiss) private var dismiss

        @State private var text: String
        @State private var aliasesText: String
        @State private var errorMessage: String?
        @State private var isSaving = false

        init(mode: EditorMode) {
            self.mode = mode
            switch mode {
            case .add:
                _text = State(initialValue: "")
                _aliasesText = State(initialValue: "")
            case .edit(let term):
                _text = State(initialValue: term.text)
                _aliasesText = State(initialValue: term.aliases.joined(separator: ", "))
            }
        }

        private var title: String {
            switch mode {
            case .add: return "Add Term"
            case .edit: return "Edit Term"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Term")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("e.g. Mac", text: $text)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aliases (comma-separated)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("e.g. MEC, Meg", text: $aliasesText)
                        .textFieldStyle(.roundedBorder)
                    Text("Aliases are optional. Separate multiple aliases with commas; blank entries are ignored.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(NeonButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Button("Save") { save() }
                        .buttonStyle(NeonButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                }
            }
            .padding(20)
            .frame(width: 400)
            .background(Theme.background)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.neon)
            .preferredColorScheme(.dark)
            .onChange(of: text) { _, _ in errorMessage = nil }
            .onChange(of: aliasesText) { _, _ in errorMessage = nil }
        }

        private func save() {
            guard !isSaving else { return }
            isSaving = true
            errorMessage = nil
            let aliases = UserDictionary.parseAliases(aliasesText)
            Task {
                defer { isSaving = false }
                do {
                    switch mode {
                    case .add:
                        _ = try await dictionary.addTerm(text: text, aliases: aliases)
                    case .edit(let term):
                        _ = try await dictionary.updateTerm(id: term.id, text: text, aliases: aliases)
                    }
                    dismiss()
                } catch {
                    errorMessage = dictionary.errorMessage(for: error)
                }
            }
        }
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
