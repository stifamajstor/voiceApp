import Foundation
import GRDB
import VoiceAppCore
import XCTest

final class DictionaryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: MemoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        store = try MemoryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try store?.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testAddEditDeleteAndReopenPreserveIdentityAndClocks() throws {
        let before = Date.now
        let term = try store.addTerm(text: "ChatGPT", aliases: ["chat GPT", "chat gpt"])
        XCTAssertEqual(term.aliases, ["chat GPT"])
        XCTAssertEqual(term.deviceID, store.deviceID)
        XCTAssertGreaterThanOrEqual(term.updatedAt, before)
        XCTAssertNil(term.deletedAt)
        let edited = try store.updateTerm(id: term.id, text: "ChatGPT Pro", aliases: ["chat pro"])
        XCTAssertEqual(edited.id, term.id)
        XCTAssertEqual(edited.deviceID, term.deviceID)
        XCTAssertGreaterThan(edited.updatedAt, term.updatedAt)
        try reopen()
        XCTAssertEqual(try store.listTerms(), [edited])
        try store.deleteTerm(id: term.id)
        let deleted = try XCTUnwrap(store.dictionaryTerm(id: term.id))
        XCTAssertNotNil(deleted.deletedAt)
        XCTAssertEqual(deleted.deletedAt, deleted.updatedAt)
        XCTAssertGreaterThan(deleted.updatedAt, edited.updatedAt)
        XCTAssertEqual(deleted.text, "")
        XCTAssertEqual(deleted.aliases, [])
        try store.deleteTerm(id: term.id)
        try reopen()
        XCTAssertEqual(try store.listTerms(), [])
        XCTAssertEqual(try store.dictionaryTerm(id: term.id), deleted)
        XCTAssertThrowsError(try store.updateTerm(id: term.id, text: "resurrect", aliases: []))
        XCTAssertNoThrow(try store.deleteTerm(id: UUID()))
        XCTAssertThrowsError(try store.updateTerm(id: UUID(), text: "missing", aliases: []))
    }

    func testEmptyTextRejectedAndHostileTextRoundTrips() throws {
        for text in ["", " \n\t", "\u{a0}"] {
            XCTAssertThrowsError(try store.addTerm(text: text)) { error in
                XCTAssertEqual(error as? DictionaryError, .emptyText)
            }
        }
        for text in ["C++", ".NET", "a|b", "(x)", #"\d"#, "!!!", " \u{301}",
                     String(repeating: "ž", count: DictionaryTerm.maximumLength)] {
            let term = try store.addTerm(text: text, aliases: ["", " \t"])
            XCTAssertEqual(try store.dictionaryTerm(id: term.id), term)
        }
        _ = try store.addTerm(text: "a b")
        XCTAssertNoThrow(try store.addTerm(text: "a \u{301}b"))
        let term = try store.addTerm(text: "Valid")
        XCTAssertThrowsError(try store.updateTerm(id: term.id, text: " ", aliases: []))
        XCTAssertEqual(try store.dictionaryTerm(id: term.id), term)
    }

    func testLengthLimitsDuplicateCollapseSelfAliasDropAndLegacyOversizedRows() throws {
        let maxText = "  " + String(repeating: "a", count: DictionaryTerm.maximumLength) + "  "
        let maxAlias = String(repeating: "b", count: DictionaryTerm.maximumLength)
        let boundary = try store.addTerm(text: maxText, aliases: [maxAlias])
        XCTAssertEqual(boundary.text.count, DictionaryTerm.maximumLength)
        XCTAssertEqual(boundary.aliases, [maxAlias])
        XCTAssertFalse(boundary.exceedsLengthLimit)

        let overText = String(repeating: "c", count: DictionaryTerm.maximumLength + 1)
        XCTAssertThrowsError(try store.addTerm(text: overText, aliases: [])) { error in
            XCTAssertEqual(error as? DictionaryError, .textTooLong(limit: DictionaryTerm.maximumLength))
        }
        let overAlias = String(repeating: "d", count: DictionaryTerm.maximumLength + 1)
        XCTAssertThrowsError(try store.addTerm(text: "Allowed", aliases: [overAlias])) { error in
            XCTAssertEqual(
                error as? DictionaryError,
                .aliasTooLong(value: overAlias, limit: DictionaryTerm.maximumLength)
            )
        }

        // Duplicate aliases collapse and self-matching aliases are dropped.
        let normalized = DictionaryTerm.normalizeAliases(["Mac", "MAC", "MEC", "mec", "Meg"], matchingText: "Mac")
        XCTAssertEqual(normalized.aliases, ["MEC", "Meg"])
        XCTAssertEqual(normalized.droppedSelfMatches, ["Mac"])
        let deduped = try store.addTerm(text: "Mac", aliases: ["mac", "MEC", "mec", "Meg"])
        XCTAssertEqual(deduped.aliases, ["MEC", "Meg"])

        // Pre-existing oversized entries in SQLite stay readable and are flagged for UI/matcher skip.
        let legacyID = UUID()
        let hugeText = String(repeating: "lorem ", count: 200)
        try store.close()
        let db = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO dictionaryTerms (id, text, aliases, updatedAt, deviceID, deletedAt) VALUES (?, ?, ?, ?, ?, NULL)",
                arguments: [legacyID.uuidString, hugeText, "[\"the\"]", 1.0, UUID().uuidString]
            )
        }
        try db.close()
        store = try MemoryStore(directory: directory)
        let loaded = try store.listTerms()
        let legacy = try XCTUnwrap(loaded.first(where: { $0.id == legacyID }))
        XCTAssertTrue(legacy.exceedsLengthLimit)
        XCTAssertTrue(legacy.hasOversizedText)
    }

    func testConflictsCoverTextAliasesUnicodeAndWhitespaceAndRollBack() throws {
        let first = try store.addTerm(text: "Straße", aliases: ["chat GPT", "ČĆŽŠĐ"])
        for (text, aliases, value) in [
            ("STRASSE", [String](), "STRASSE"), ("Other", ["straße"], "straße"),
            ("CHAT\n  gpt", [], "CHAT\n  gpt"), ("Other", ["čćžšđ"], "čćžšđ"),
        ] {
            XCTAssertThrowsError(try store.addTerm(text: text, aliases: aliases)) { error in
                XCTAssertEqual(error as? DictionaryError, .conflict(value: value, termID: first.id))
            }
        }
        let second = try store.addTerm(text: "Second", aliases: ["other"])
        XCTAssertThrowsError(try store.updateTerm(id: second.id, text: "Second", aliases: ["CHAT GPT"]))
        XCTAssertEqual(try store.dictionaryTerm(id: second.id), second)
        XCTAssertNoThrow(try store.updateTerm(id: first.id, text: "Straße", aliases: ["CHAT GPT", "chat gpt"]))
        try store.deleteTerm(id: first.id)
        XCTAssertNoThrow(try store.addTerm(text: "STRASSE", aliases: ["chat GPT"]))
    }

    func testListIncludesEveryLiveTermInStableOrder() throws {
        let first = try store.addTerm(text: "First")
        let deleted = try store.addTerm(text: "Deleted")
        let last = try store.addTerm(text: "Last")
        try store.deleteTerm(id: deleted.id)
        let expected = [first, last].sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(try store.listTerms(), expected)
        try reopen()
        XCTAssertEqual(try store.listTerms(), expected)
    }

    func testConcurrentDuplicateAttemptsHaveExactlyOneWinner() async throws {
        let store = try XCTUnwrap(store)
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { (try? store.addTerm(text: "Shared")) != nil }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(winners, 1)
        XCTAssertEqual(try store.listTerms().count, 1)
    }

    func testDictionaryWritesDoNotChangeRecordStorageOrSearch() throws {
        let record = try store.append(rawText: "record survivor")
        let term = try store.addTerm(text: "Example")
        _ = try store.updateTerm(id: term.id, text: "Edited", aliases: ["edit"])
        try store.deleteTerm(id: term.id)
        XCTAssertEqual(try store.fetch(id: record.id), record)
        XCTAssertEqual(try store.search("survivor"), [record])
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
    }

    func testMigrationUpgradesMainDatabaseOnceWithoutChangingRecords() throws {
        try store.close()
        // Generated with the unmodified store sources at main 29e9eda, including a live record and tombstone.
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "main-29e9eda-store", withExtension: "sqlite", subdirectory: "Fixtures"))
        try FileManager.default.removeItem(at: directory.appending(path: "store.sqlite"))
        try FileManager.default.copyItem(at: fixture, to: directory.appending(path: "store.sqlite"))
        store = try MemoryStore(directory: directory)
        let identity = store.deviceID
        let record = try XCTUnwrap(store.listRecent().first)
        XCTAssertEqual(record.rawText, "main migration survivor")
        XCTAssertEqual(try store.search("survivor"), [record])
        let term = try store.addTerm(text: "Migrated")
        for _ in 0..<3 {
            try reopen()
            XCTAssertEqual(store.deviceID, identity)
            XCTAssertEqual(try store.fetch(id: record.id), record)
            XCTAssertEqual(try store.listTerms(), [term])
        }
        try store.close()
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        let migrations = try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM records WHERE deletedAt IS NOT NULL"), 1)
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        try database.close()
        XCTAssertEqual(migrations, [
            "memoryStore.createRecords",
            "memoryStore.indexRecordText",
            "dictionary.createTerms",
            "notes.createState",
            "notes.localReminders",
            "notes.reminderHandoff",
            "correction.addMetadata",
            "notes.reminderState",
        ])
        store = try MemoryStore(directory: directory)
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
    }

    func testAddAndUpdateTrimWhitespaceAndDropBlankAliases() throws {
        let added = try store.addTerm(text: "  Mac\t\n", aliases: [" MEC ", "", " \n\t ", "\u{a0}Meg\u{a0}"])
        XCTAssertEqual(added.text, "Mac")
        XCTAssertEqual(added.aliases, ["MEC", "Meg"])
        XCTAssertEqual(try store.dictionaryTerm(id: added.id), added)

        XCTAssertThrowsError(try store.addTerm(text: "Other", aliases: ["  mec \n"])) { error in
            XCTAssertEqual(error as? DictionaryError, .conflict(value: "mec", termID: added.id))
        }

        let updated = try store.updateTerm(id: added.id, text: "\u{a0}MacBook\t", aliases: ["  ", " mac book ", "\n"])
        XCTAssertEqual(updated.text, "MacBook")
        XCTAssertEqual(updated.aliases, ["mac book"])
        XCTAssertEqual(try store.dictionaryTerm(id: added.id), updated)
    }

    func testUpdateAndDeleteRecordCurrentDeviceID() throws {
        let updatedTerm = try store.addTerm(text: "UpdateMe")
        let deletedTerm = try store.addTerm(text: "DeleteMe")
        let otherDeviceID = UUID()
        XCTAssertNotEqual(otherDeviceID, store.deviceID)
        try store.close()
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        try database.write { db in
            try db.execute(sql: "UPDATE dictionaryTerms SET deviceID = ?", arguments: [otherDeviceID.uuidString])
        }
        try database.close()
        store = try MemoryStore(directory: directory)
        let edited = try store.updateTerm(id: updatedTerm.id, text: "Updated", aliases: [])
        XCTAssertEqual(edited.deviceID, store.deviceID)
        try store.deleteTerm(id: deletedTerm.id)
        let tombstone = try XCTUnwrap(store.dictionaryTerm(id: deletedTerm.id))
        XCTAssertEqual(tombstone.deviceID, store.deviceID)
    }

    private func reopen() throws {
        try store.close()
        store = try MemoryStore(directory: directory)
    }
}
