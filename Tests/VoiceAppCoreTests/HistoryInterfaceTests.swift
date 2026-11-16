import Foundation
@testable import VoiceAppCore
import XCTest

@MainActor
final class HistoryInterfaceTests: XCTestCase {
    func testMenuExplainsSavingOnOffAndUnavailableStore() async {
        let name = "HistoryInterfaceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = DictationHistory(repository: UnavailableRepository(), notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        XCTAssertEqual(history.savingDisclosure,
                       "Dictations are saved on this Mac. Turn off in Settings → Behavior.")
        history.saveEnabled = false
        XCTAssertEqual(history.savingDisclosure,
                       "New dictations are not saved. Turn on in Settings → Behavior.")
        history.saveEnabled = true
        await history.start().value
        XCTAssertEqual(history.savingDisclosure,
                       "Dictation history is not being saved. Dictation still works. The cause is in the log.")
        history.saveEnabled = false
        XCTAssertEqual(history.savingDisclosure,
                       "Dictation history is not being saved. Dictation still works. The cause is in the log.")
    }
}

private struct UnavailableRepository: HistoryRepository {
    func appendNote(_ note: CompletedDictation) async throws { throw CocoaError(.featureUnsupported) }
    func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote] { [] }
    func editNote(id: UUID, text: String) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteDone(id: UUID, isDone: Bool) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteReminder(id: UUID, date: Date?) async throws { throw CocoaError(.featureUnsupported) }

    func open() async throws { throw CocoaError(.fileReadNoPermission) }
    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord { throw CocoaError(.fileWriteNoPermission) }
    func records(query: String, limit: Int) async throws -> [MemoryRecord] { [] }
    func delete(ids: [UUID]) async throws {}
    func deleteAll() async throws {}
}
