import AppKit
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

            CorrectionSection()

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
/// A duplicate saved by an earlier build is shown too, never silently disabled.
private struct ValidatedShortcutRecorder: View {
    private static let names: [KeyboardShortcuts.Name] = [.pushToTalk, .toggleToTalk, .notePushToTalk, .noteToggle]
    private static let titles = ["Push to talk — key combo", "Toggle to talk — key combo", "Note — push to talk", "Note — toggle"]
    // KeyboardShortcuts posts this when any binding changes; its name is not public API.
    private static let changed = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
    let title: String
    let name: KeyboardShortcuts.Name
    @State private var accepted: KeyboardShortcuts.Shortcut?
    @State private var message: String?
    @State private var changeCount = 0

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
        _accepted = State(initialValue: KeyboardShortcuts.getShortcut(for: name))
    }

    private var existingConflict: String? {
        guard let index = Self.names.firstIndex(of: name) else { return nil }
        let others = ShortcutValidation.conflicts(of: index, in: Self.names.map { KeyboardShortcuts.getShortcut(for: $0) })
            .map { "“\(Self.titles[$0])”" }
        guard !others.isEmpty else { return nil }
        return "Also assigned to \(others.joined(separator: " and ")). Only one of them will respond. Record a different combination."
    }

    var body: some View {
        let _ = changeCount
        KeyboardShortcuts.Recorder(title, name: name) { candidate in
            let result = ShortcutValidation.resolve(candidate: candidate, previous: accepted,
                others: Self.names.filter { $0 != name }.map { KeyboardShortcuts.getShortcut(for: $0) })
            message = result.message
            accepted = result.value
            if result.message != nil { KeyboardShortcuts.setShortcut(result.value, for: name) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.changed)) { _ in changeCount += 1 }
        if let text = message ?? existingConflict { Text(text).font(.callout).foregroundStyle(Theme.warning) }
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
    @State private var saveNotice: String?

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

    private var lengthWarning: String? {
        let entries = dictionary.oversizedTerms.filter(\.hasOversizedText).count
        let aliases = dictionary.oversizedTerms.filter { !$0.hasOversizedText }
            .reduce(0) { $0 + $1.oversizedAliases.count }
        var skipped: [String] = []
        if entries > 0 { skipped.append("\(entries) whole \(entries == 1 ? "entry" : "entries")") }
        if aliases > 0 { skipped.append("\(aliases) \(aliases == 1 ? "alias" : "aliases")") }
        guard !skipped.isEmpty else { return nil }
        return "Skipped during dictation: " + skipped.joined(separator: "; ")
            + ". Limit: \(DictionaryTerm.maximumLength) characters and Unicode scalars per value."
    }

    private var summaryText: String {
        if dictionary.isLoading { return "Loading dictionary…" }
        if dictionary.storeError != nil {
            if dictionary.isRetrying { return "Retrying dictionary load…" }
            if dictionary.isRetryScheduled { return "Dictionary unavailable — retrying automatically" }
            return "Dictionary unavailable"
        }
        if dictionary.terms.isEmpty { return "No terms yet" }
        if !trimmedQuery.isEmpty {
            return "\(filteredTerms.count) of \(dictionary.terms.count) terms"
        }
        let count = dictionary.terms.count
        return "\(count) \(count == 1 ? "term" : "terms")"
    }

    private var deleteAlertTitle: String {
        guard let term = termPendingDeletion, !term.text.isEmpty else {
            return "Delete term?"
        }
        return "Delete \"\(term.text)\"?"
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
                    saveNotice = nil
                    editorMode = .add
                }
                .buttonStyle(NeonButtonStyle(prominent: true))
                .disabled(dictionary.isLoading || dictionary.storeError != nil)
            }

            if let storeError = dictionary.storeError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(storeError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                    HStack(spacing: 8) {
                        if dictionary.isRetrying {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.neon)
                            Text("Retrying…")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Button("Retry") {
                                dictionary.retryLoadIfNeeded()
                            }
                            .buttonStyle(NeonButtonStyle())
                            if dictionary.isRetryScheduled {
                                Text("Will retry automatically.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            } else if let deleteError {
                Label(deleteError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .font(.callout)
            }

            if let saveNotice {
                Label(saveNotice, systemImage: "info.circle")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.callout)
            }

            if let lengthWarning {
                Label(
                    lengthWarning,
                    systemImage: "exclamationmark.triangle"
                )
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
            Text("Terms and aliases (up to \(DictionaryTerm.maximumLength) characters and Unicode scalars each) match whole words case-insensitively before pasting and are stored locally.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .onAppear {
            dictionary.retryLoadIfNeeded()
        }
        .sheet(item: $editorMode) { mode in
            TermEditorSheet(mode: mode) { droppedSelfAliases in
                if droppedSelfAliases.isEmpty {
                    saveNotice = nil
                } else {
                    let quoted = droppedSelfAliases.map { "\"\($0)\"" }.joined(separator: ", ")
                    saveNotice = "Ignored \(droppedSelfAliases.count == 1 ? "alias" : "aliases") matching the term itself: \(quoted)."
                }
            }
            .environmentObject(dictionary)
        }
        .alert(
            deleteAlertTitle,
            isPresented: $isDeleteConfirmationPresented,
            presenting: termPendingDeletion
        ) { term in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
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
                    .lineLimit(2)
                if !term.aliases.isEmpty {
                    Text(term.aliases.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                if term.exceedsLengthLimit {
                    Label(
                        term.hasOversizedText
                            ? "Term exceeds the length limit — whole entry skipped during dictation."
                            : "\(term.oversizedAliases.count) oversized \(term.oversizedAliases.count == 1 ? "alias" : "aliases") skipped; term and other aliases still apply.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: 0)
            Button("Edit") {
                deleteError = nil
                saveNotice = nil
                editorMode = .edit(term)
            }
            .buttonStyle(NeonButtonStyle())
            .accessibilityLabel("Edit \(term.text)")
            Button(role: .destructive) {
                deleteError = nil
                saveNotice = nil
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
        let onSaved: ([String]) -> Void
        @EnvironmentObject private var dictionary: UserDictionary
        @Environment(\.dismiss) private var dismiss

        @State private var text: String
        @State private var aliasesText: String
        @State private var errorMessage: String?
        @State private var isSaving = false

        init(mode: EditorMode, onSaved: @escaping ([String]) -> Void) {
            self.mode = mode
            self.onSaved = onSaved
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

        private var pendingSelfMatches: [String] {
            let parsed = UserDictionary.parseAliases(aliasesText)
            return DictionaryTerm.normalizeAliases(parsed, matchingText: text).droppedSelfMatches
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
                    Text("Optional, up to \(DictionaryTerm.maximumLength) characters and Unicode scalars each. Duplicate or blank aliases are ignored.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if !pendingSelfMatches.isEmpty {
                    let quoted = pendingSelfMatches.map { "\"\($0)\"" }.joined(separator: ", ")
                    Label(
                        "Alias \(quoted) matches the term itself and will be removed.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(Theme.textSecondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
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
            let parsed = UserDictionary.parseAliases(aliasesText)
            let normalized = DictionaryTerm.normalizeAliases(parsed, matchingText: text)
            Task {
                defer { isSaving = false }
                do {
                    switch mode {
                    case .add:
                        _ = try await dictionary.addTerm(text: text, aliases: normalized.aliases)
                    case .edit(let term):
                        _ = try await dictionary.updateTerm(id: term.id, text: text, aliases: normalized.aliases)
                    }
                    onSaved(normalized.droppedSelfMatches)
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

// MARK: - Cloud correction

private struct CorrectionSection: View {
    private struct RunningAppOption: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    @EnvironmentObject private var correction: CloudCorrectionService
    @State private var apiKeyInput = ""
    @State private var excludedBundleInput = ""
    @State private var runningApps: [RunningAppOption] = []

    private var hasSavedKey: Bool {
        correction.hasKey(for: correction.selectedProvider)
    }

    private var trimmedAPIKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedExcludedBundleInput: String {
        excludedBundleInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Section {
            Toggle("Correct dictations with a cloud model", isOn: $correction.isEnabled)
                .toggleStyle(.switch)

            if correction.isEnabled && !hasSavedKey {
                Label(
                    "Add an \(correction.selectedProvider.displayName) API key below before cloud correction runs.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Theme.warning)
                .font(.callout)
            }

            if correction.isCircuitOpen {
                Label(
                    "Paused for 5 minutes after 3 consecutive failures. Dictation uses dictionary text until then.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Theme.warning)
                .font(.callout)
            }

            Picker("Provider", selection: $correction.selectedProvider) {
                ForEach(CloudProviderID.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(correction.selectedProvider.displayName) API key")
                    Spacer()
                    Text(hasSavedKey ? "Saved in login Keychain" : "Not set")
                        .font(.caption)
                        .foregroundStyle(hasSavedKey ? Theme.neon : Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    SecureField(
                        hasSavedKey ? "Enter new key to replace" : "Paste API key",
                        text: $apiKeyInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKeyAndRefresh() }

                    Button("Save") {
                        saveKeyAndRefresh()
                    }
                    .buttonStyle(NeonButtonStyle(prominent: true))
                    .disabled(trimmedAPIKeyInput.isEmpty)

                    if hasSavedKey {
                        Button("Remove", role: .destructive) {
                            try? correction.removeAPIKey()
                            apiKeyInput = ""
                        }
                        .buttonStyle(NeonButtonStyle())
                    }
                }
                Text("Stored in your macOS login Keychain (not synced to iCloud; may transfer via Migration Assistant).")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let keyError = correction.keyStoreError {
                Label(keyError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Picker("Model", selection: Binding(
                    get: { correction.currentModelID },
                    set: { correction.setSelectedModelID($0) }
                )) {
                    ForEach(correction.currentModels) { model in
                        Text(modelLabel(for: model)).tag(model.id)
                    }
                }

                if correction.isRefreshingModels {
                    ProgressView().controlSize(.small).tint(Theme.neon)
                } else {
                    Button("Refresh") {
                        Task { await correction.refreshModels() }
                    }
                    .buttonStyle(NeonButtonStyle())
                    .disabled(!hasSavedKey)
                }

                Button("Test") {
                    runTest()
                }
                .buttonStyle(NeonButtonStyle())
                .disabled((!hasSavedKey && trimmedAPIKeyInput.isEmpty) || correction.testState == .testing)
            }

            if let modelsError = correction.modelsError {
                Label(modelsError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .font(.callout)
            }

            testStatusView

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Excluded apps")
                        Text("Transcripts are never sent when focused in these apps.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Menu("Add Running App…") {
                        if runningApps.isEmpty {
                            Text("No other running apps")
                        } else {
                            ForEach(runningApps) { app in
                                Button("\(app.name) (\(app.bundleID))") {
                                    correction.addExcludedBundleID(app.bundleID)
                                }
                            }
                        }
                    }
                    .onAppear { refreshRunningApps() }
                }

                HStack(spacing: 8) {
                    TextField("Bundle ID (e.g. com.apple.Terminal)", text: $excludedBundleInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addExcludedInput() }

                    Button("Add") {
                        addExcludedInput()
                    }
                    .buttonStyle(NeonButtonStyle())
                    .disabled(trimmedExcludedBundleInput.isEmpty)
                }

                if correction.excludedBundleIDs.isEmpty {
                    Text("No excluded apps.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(correction.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                if let appName = appName(for: bundleID) {
                                    Text(appName)
                                        .font(.callout.weight(.medium))
                                    Text(bundleID)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                } else {
                                    Text(bundleID)
                                        .font(.callout)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                correction.removeExcludedBundleID(bundleID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.danger)
                            .help("Remove excluded app")
                            .accessibilityLabel("Remove \(bundleID)")
                        }
                    }
                }
            }
        } header: {
            SectionTitle("Correction")
        } footer: {
            Text(correction.selectedProvider.privacyNotice)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .task {
            refreshRunningApps()
            await correction.refreshKeyPresence()
            if hasSavedKey {
                await correction.refreshModels()
            }
        }
        .onChange(of: correction.selectedProvider) { _, newProvider in
            apiKeyInput = ""
            Task {
                await correction.refreshKeyPresence(for: newProvider)
                if correction.hasKey(for: newProvider) {
                    await correction.refreshModels(for: newProvider)
                }
            }
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch correction.testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.neon)
                Text("Sending test request…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .succeeded(let ms, let modelID):
            Label(
                ms > 2000
                    ? "Connected (\(modelID)) in \(ms) ms — slower than the 2.0 s dictation limit"
                    : "Connected (\(modelID)) in \(ms) ms",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(ms > 2000 ? Theme.warning : Theme.neon)
            .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warning)
                .font(.callout)
        }
    }

    private func modelLabel(for model: CloudModelOption) -> String {
        model.displayName == model.id ? model.id : "\(model.displayName) (\(model.id))"
    }

    private func saveKeyAndRefresh() {
        let key = trimmedAPIKeyInput
        guard !key.isEmpty else { return }
        do {
            try correction.saveAPIKey(key)
            apiKeyInput = ""
            Task { await correction.refreshModels() }
        } catch {
            // keyStoreError is already published on correction.
        }
    }

    private func runTest() {
        if !trimmedAPIKeyInput.isEmpty {
            do {
                try correction.saveAPIKey(trimmedAPIKeyInput)
                apiKeyInput = ""
            } catch {
                return
            }
        }
        Task {
            await correction.testConnection()
            if correction.hasKey(for: correction.selectedProvider) {
                await correction.refreshModels()
            }
        }
    }

    private func addExcludedInput() {
        guard !trimmedExcludedBundleInput.isEmpty else { return }
        correction.addExcludedBundleID(trimmedExcludedBundleInput)
        excludedBundleInput = ""
    }

    private func refreshRunningApps() {
        let ownBundleID = Bundle.main.bundleIdentifier
        var seen: Set<String> = []
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  bundleID != ownBundleID,
                  app.activationPolicy != .prohibited,
                  seen.insert(bundleID.lowercased()).inserted else {
                return nil
            }
            return RunningAppOption(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(for bundleID: String) -> String? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }), let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return nil
    }
}
