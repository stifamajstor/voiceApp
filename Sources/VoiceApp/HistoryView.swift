import SwiftUI
import VoiceAppCore

struct HistoryView: View {
    @EnvironmentObject private var history: DictationHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle("Dictation history")
                Spacer()
                if history.isOpening || history.isSearching || history.isDeleting {
                    ProgressView().controlSize(.small)
                    Text(history.isDeleting ? "Deleting…" : history.isOpening ? "Opening…" : "Searching…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            TextField("Search dictations", text: $history.query)
                .textFieldStyle(.roundedBorder)
                .disabled(history.isOpening || history.storeError != nil)
                .help("Search words in the transcript; the last word matches prefixes.")

            if let error = history.storeError ?? history.deleteError ?? history.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .textSelection(.enabled)
            }

            List(selection: $history.selection) {
                ForEach(history.results) { record in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                                if let name = record.appName { Text("· \(name)") }
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            Text(record.finalText)
                                .lineLimit(3)
                                .font(.body)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            TextInserter.copy(record.finalText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(NeonButtonStyle())
                        .help("Copy transcript")
                        .accessibilityLabel("Copy transcript")
                    }
                    .padding(.vertical, 8)
                    .tag(record.id)
                    .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if history.results.isEmpty && !history.isOpening && !history.isSearching && !history.isDeleting && history.storeError == nil {
                    Text(history.query.isEmpty ? "No dictations saved yet." : "No matching dictations.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onDeleteCommand(perform: history.requestDeleteSelected)

            HStack {
                Text("\(history.results.count) results\(history.hasMore ? " · More available" : "")")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if history.hasMore {
                    Button("Load more") { Task { await history.loadMore() } }
                        .disabled(history.isSearching || history.isDeleting)
                }
                Spacer()
                Button("Delete selected (\(history.selection.count))", role: .destructive,
                       action: history.requestDeleteSelected)
                .disabled(history.selection.isEmpty || history.isSearching || history.isDeleting)
                Button("Delete all…", role: .destructive, action: history.requestDeleteAll)
                .disabled(history.isOpening || history.isDeleting || history.storeError != nil)
            }
            .buttonStyle(NeonButtonStyle())

            Text("Use ⌘-click or ⇧-click to select multiple dictations. Copy text, then paste it into another app.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.neon)
        .preferredColorScheme(.dark)
        .alert(history.deleteConfirmationTitle, isPresented: $history.isDeleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {
                history.cancelDeleteAll()
                history.cancelDeleteSelected()
            }
            Button("Delete", role: .destructive) {
                if history.needsDeleteAllConfirmation { history.confirmDeleteAll() }
                else { history.deleteSelected() }
            }
        } message: {
            Text(history.needsDeleteAllConfirmation
                 ? "This permanently deletes \(deleteCount) \(deleteCount == 1 ? "dictation" : "dictations"), including records outside the current search. This cannot be undone."
                 : "This permanently deletes \(deleteCount) selected \(deleteCount == 1 ? "dictation" : "dictations"). This cannot be undone.")
        }
    }

    private var deleteCount: Int {
        history.needsDeleteAllConfirmation ? history.deleteAllCount : history.selectedDeleteCount
    }
}

@MainActor
final class HistoryWindowController: ObservableObject {
    private let history: DictationHistory
    private var window: NSWindow?

    init(history: DictationHistory) {
        self.history = history
    }

    func show() {
        if window == nil {
            // Create only on demand so a history window never opens at menu-bar app launch.
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: HistoryView().environmentObject(history)))
            window.title = "Dictation History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 580))
            window.minSize = NSSize(width: 640, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await history.refresh() }
    }
}
