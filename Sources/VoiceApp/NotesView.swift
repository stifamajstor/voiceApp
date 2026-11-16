import AppKit
import SwiftUI
import VoiceAppCore

struct NotesView: View {
    @EnvironmentObject private var history: DictationHistory
    @State private var editing: VoiceNote?
    @State private var reminding: VoiceNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle("Voice notes")
                Spacer()
                if history.isOpening || history.isSearchingNotes || history.pendingNoteOperations > 0 {
                    ProgressView().controlSize(.small)
                }
            }
            TextField("Search notes", text: $history.noteQuery)
                .textFieldStyle(.roundedBorder)
                .disabled(history.isOpening || history.storeError != nil)
                .help("Search the current note text; the last word matches prefixes.")
            if let error = history.noteDeleteError ?? history.noteError ?? history.noteSearchError ?? history.storeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .textSelection(.enabled)
            }
            if history.reminderAccessDenied {
                Button("Open Reminders Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }
            }
            List {
                ForEach(history.notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(note.record.createdAt, format: .dateTime.year().month().day().hour().minute())
                            if let app = note.record.appName { Text("· \(app)") }
                            Spacer()
                            if note.isDone { Label("Done", systemImage: "checkmark.circle.fill") }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        Text(note.text)
                            .strikethrough(note.isDone)
                            .foregroundStyle(note.isDone ? Theme.textSecondary : Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Copy") { TextInserter.copy(note.text) }
                            Button("Edit…") { editing = note }
                            Button(note.isDone ? "Mark not done" : "Mark done") {
                                history.setNoteDone(id: note.id, isDone: !note.isDone)
                            }
                            Spacer()
                            if note.reminderID != nil {
                                Button("Undo reminder") { history.undoNoteReminder(id: note.id) }
                            } else {
                                Button("Remind me…") { reminding = note }
                            }
                            Button("Delete…", role: .destructive) { history.requestDeleteNote(note) }
                        }
                        .disabled(history.pendingNoteOperations > 0)
                        .buttonStyle(NeonButtonStyle())
                        if let date = note.reminderDate {
                            Label("Reminder: \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "bell")
                                .font(.caption)
                                .foregroundStyle(Theme.neon)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .overlay {
                if history.notes.isEmpty && !history.isOpening && !history.isSearchingNotes {
                    ContentUnavailableView(history.noteQuery.isEmpty ? "No notes yet" : "No matching notes",
                        systemImage: "note.text", description: Text("Set a note shortcut in Settings, then speak a thought."))
                }
            }
            HStack {
                Text("Saved on this Mac. Note shortcuts are configured in Settings.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                if history.hasMoreNotes {
                    Button("Load more") { Task { await history.loadMoreNotes() } }
                        .disabled(history.isSearchingNotes)
                }
                Button("Refresh") { Task { await history.refreshNotes() } }
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.neon)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { note in
            NoteEditor(note: note) { text in
                await withCheckedContinuation { continuation in
                    history.editNote(id: note.id, text: text) { error in
                        continuation.resume(returning: error)
                    }
                }
            }
        }
        .sheet(item: $reminding) { note in
            NoteReminderPicker(note: note) { date in history.remindNote(id: note.id, date: date) }
        }
        .alert("Delete note?", isPresented: $history.isNoteDeleteConfirmationPresented) {
            Button("Cancel", role: .cancel) { history.cancelDeleteNote() }
            Button("Delete", role: .destructive) { history.confirmDeleteNote() }
        } message: {
            Text("This permanently deletes the note and removes its linked Apple Reminder, if any. This cannot be undone.")
        }
    }
}

private struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var error: String?
    let save: (String) async -> String?

    init(note: VoiceNote, save: @escaping (String) async -> String?) {
        _text = State(initialValue: note.text)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit note").font(.headline)
            TextEditor(text: $text).frame(minHeight: 180).disabled(isSaving)
            if let error { Text(error).foregroundStyle(Theme.warning) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSaving ? "Saving…" : "Save") {
                    isSaving = true
                    Task {
                        error = await save(text)
                        isSaving = false
                        if error == nil { dismiss() }
                    }
                }
                    .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 500)
    }
}

private struct NoteReminderPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date(timeIntervalSince1970: floor(Date.now.addingTimeInterval(3600).timeIntervalSince1970 / 60) * 60)
    let note: VoiceNote
    let save: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remind me…").font(.headline)
            Text(note.text).lineLimit(3)
            DatePicker("Date and time", selection: $date, displayedComponents: [.date, .hourAndMinute])
            Text("Creates an Apple Reminder in your default list. You can undo it from this note.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create reminder") { save(date); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 500)
    }
}

@MainActor
final class NotesWindowController: ObservableObject {
    private let history: DictationHistory
    private var window: NSWindow?

    init(history: DictationHistory) { self.history = history }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: NotesView().environmentObject(history)))
            window.title = "Voice Notes"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 840, height: 580))
            window.minSize = NSSize(width: 720, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await history.refreshNotes() }
    }
}
