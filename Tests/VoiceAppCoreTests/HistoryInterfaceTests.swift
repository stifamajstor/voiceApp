import Foundation
@testable import VoiceAppCore
import XCTest

@MainActor
final class HistoryInterfaceTests: XCTestCase {
    func testMenuExplainsSavingOnOffAndUnavailableStore() async {
        let name = "HistoryInterfaceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = DictationHistory(repository: UnavailableRepository(), defaults: defaults, log: { _ in })
        XCTAssertEqual(history.savingDisclosure,
                       "Dictations are saved on this Mac. Turn off in Settings → Behavior.")
        history.saveEnabled = false
        XCTAssertEqual(history.savingDisclosure,
                       "New dictations are not saved. Turn on in Settings → Behavior.")
        history.saveEnabled = true
        await history.start().value
        XCTAssertEqual(history.savingDisclosure,
                       "Dictation history is not being saved. Open Settings → Behavior for the reason.")
        history.saveEnabled = false
        XCTAssertEqual(history.savingDisclosure,
                       "Dictation history is not being saved. Open Settings → Behavior for the reason.")
    }
}

private struct UnavailableRepository: HistoryRepository {
    func open() async throws { throw CocoaError(.fileReadNoPermission) }
    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord { throw CocoaError(.fileWriteNoPermission) }
    func records(query: String, limit: Int) async throws -> [MemoryRecord] { [] }
    func delete(ids: [UUID]) async throws {}
    func deleteAll() async throws {}
}
