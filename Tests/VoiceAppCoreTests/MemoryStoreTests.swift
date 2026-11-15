import Foundation
import GRDB
import VoiceAppCore
import XCTest

final class MemoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: MemoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        store = try MemoryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try store?.close()
        store = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testRecordSurvivesCloseAndReopen() throws {
        let record = try store.append(
            kind: .note, createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            rawText: "original words", finalText: "corrected words",
            appBundleID: "com.apple.TextEdit", appName: "TextEdit", project: "Journal",
            modelID: "whisper-tiny", durationSeconds: 3.25, audioPath: "audio/recording.wav"
        )
        try reopen()
        XCTAssertEqual(try store.fetch(id: record.id), record)
        XCTAssertEqual(try store.listRecent(), [record])
        XCTAssertEqual(try store.search("corrected"), [record])
        XCTAssertNil(record.deletedAt)
    }

    func testFinalTextDefaultsToRawText() throws {
        let record = try store.append(rawText: "unchanged")
        XCTAssertEqual(try store.fetch(id: record.id)?.finalText, "unchanged")
        XCTAssertEqual(record.deviceID, store.deviceID)
        XCTAssertEqual(record.kind, .dictation)
    }

    func testDeviceIDIsStableAndDifferentForAnotherInstall() throws {
        let deviceID = store.deviceID
        try reopen()
        XCTAssertEqual(store.deviceID, deviceID)
        let otherDirectory = directory.appending(path: "other-install")
        let other = try MemoryStore(directory: otherDirectory)
        defer { try? other.close() }
        XCTAssertNotEqual(other.deviceID, deviceID)
    }

    func testRepeatedReopenPreservesExistingRecordsAndIdentity() throws {
        let record = try store.append(rawText: "migration survivor")
        let deviceID = store.deviceID
        for _ in 0..<3 {
            try reopen()
            XCTAssertEqual(store.deviceID, deviceID)
            XCTAssertEqual(try store.listRecent(), [record])
            XCTAssertEqual(try store.search("survivor"), [record])
        }
    }

    func testSearchFindsRawAndFinalTextWithUnicodeWords() throws {
        let record = try store.append(rawText: "original café", finalText: "revised 東京")
        XCTAssertEqual(try store.search("original"), [record])
        XCTAssertEqual(try store.search("revised"), [record])
        XCTAssertEqual(try store.search("CAFE"), [record])
        XCTAssertEqual(try store.search("東京"), [record])
        XCTAssertEqual(try store.search("original revised"), [record])
        XCTAssertEqual(try store.search("absent"), [])
    }

    func testKindFiltersListingsAndSearch() throws {
        let dictation = try store.append(kind: .dictation, rawText: "shared word")
        let note = try store.append(kind: .note, rawText: "shared word")
        let prompt = try store.append(kind: .prompt, rawText: "shared word")
        for record in [dictation, note, prompt] {
            XCTAssertEqual(try store.listRecent(kind: record.kind), [record])
            XCTAssertEqual(try store.search("shared", kind: record.kind), [record])
        }
        XCTAssertEqual(try store.listRecent().count, 3)
        XCTAssertEqual(try store.search("shared").count, 3)
    }

    func testNewestFirstOrderingAndLimitsUseCreationTime() throws {
        let middle = try store.append(createdAt: Date(timeIntervalSince1970: 200), rawText: "match")
        let newest = try store.append(createdAt: Date(timeIntervalSince1970: 300), rawText: "match")
        let oldest = try store.append(createdAt: Date(timeIntervalSince1970: 100), rawText: "match")
        XCTAssertEqual(try store.listRecent(), [newest, middle, oldest])
        XCTAssertEqual(try store.search("match"), [newest, middle, oldest])
        XCTAssertEqual(try store.listRecent(limit: 2), [newest, middle])
        XCTAssertEqual(try store.search("match", limit: 1), [newest])
        XCTAssertEqual(try store.listRecent(limit: 0), [])
        XCTAssertEqual(try store.search("match", limit: -1), [])
    }

    func testDeleteRemovesTextAndAudioAndPersistsOnlyTombstone() throws {
        let audio = directory.appending(path: "audio/clip.wav")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audio)
        let record = try store.append(
            rawText: "private original", finalText: "private correction", appBundleID: "com.example.editor",
            appName: "Editor", project: "Secret", modelID: "model", durationSeconds: 2,
            audioPath: "audio/clip.wav"
        )
        let survivor = try store.append(rawText: "private survivor")
        let before = Date.now
        try store.delete(id: record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let tombstone = try XCTUnwrap(store.tombstone(id: record.id))
        XCTAssertEqual(tombstone.id, record.id)
        XCTAssertEqual(tombstone.deviceID, record.deviceID)
        XCTAssertGreaterThanOrEqual(tombstone.deletedAt, before)
        XCTAssertLessThanOrEqual(tombstone.deletedAt, .now)

        try reopen()
        XCTAssertNil(try store.fetch(id: record.id))
        XCTAssertEqual(try store.listRecent(), [survivor])
        XCTAssertEqual(try store.search("private"), [survivor])
        XCTAssertEqual(try store.search("original"), [])
        XCTAssertEqual(try store.search("correction"), [])
        XCTAssertEqual(try store.tombstone(id: record.id), tombstone)
        try store.delete(id: record.id)
        XCTAssertEqual(try store.tombstone(id: record.id), tombstone)

        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        let row = try database.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM records WHERE id = ?", arguments: [record.id.uuidString]))
        }
        for column in row.columnNames where !["id", "deviceID", "deletedAt"].contains(column) {
            XCTAssertTrue(row[column] == DatabaseValue.null, "Retained deleted field: \(column)")
        }
    }

    func testDeleteAllowsMissingAudioAndUnknownID() throws {
        let record = try store.append(rawText: "already removed", audioPath: "missing.wav")
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
        let unknown = UUID()
        try store.delete(id: unknown)
        XCTAssertNil(try store.tombstone(id: unknown))
    }

    func testHostileSearchInputIsLiteralAndNeverBecomesFTSSyntax() throws {
        let record = try store.append(rawText: "alpha beta")
        _ = try store.append(rawText: "alphabet")
        for query in ["\"alpha", "alpha\"", "alpha*", "-alpha", "alpha:beta", "alpha - beta", "{alpha}"] {
            XCTAssertEqual(try store.search(query), [record], query)
        }
        for query in ["", " ", "\"", "*", "-", ":", "\"*-:", "😀", "alpha OR beta", "rawText:alpha", "NEAR(alpha beta)", "alpha NOT beta", "') OR 1=1 --"] {
            XCTAssertEqual(try store.search(query), [], query)
        }
        let operators = try store.append(rawText: "alpha OR beta")
        XCTAssertEqual(try store.search("alpha OR beta"), [operators])
    }

    func testAudioPathsCannotDeleteOutsideStoreOrDatabaseFiles() throws {
        for path in ["", "../outside.wav", "/tmp/outside.wav", "audio/../../outside.wav", "store.sqlite", "STORE.SQLITE", "store.sqlite-wal", ".", "audio//clip.wav", "clip\0.wav"] {
            XCTAssertThrowsError(try store.append(rawText: "invalid", audioPath: path), path)
        }
        let link = directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.deletingLastPathComponent())
        XCTAssertThrowsError(try store.append(rawText: "invalid", audioPath: "link/outside.wav"))
        let dangling = directory.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appending(path: "absent"))
        XCTAssertThrowsError(try store.append(rawText: "invalid", audioPath: "dangling/clip.wav"))
        XCTAssertEqual(try store.listRecent(), [])
    }

    func testFailedAudioDeletionKeepsRecordAvailableForRetry() throws {
        let record = try store.append(rawText: "keep until removed", audioPath: "clip.wav")
        let audio = directory.appending(path: "clip.wav")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.delete(id: record.id))
        XCTAssertEqual(try store.fetch(id: record.id), record)
        XCTAssertNil(try store.tombstone(id: record.id))
        XCTAssertEqual(try store.search("keep"), [record])
        try FileManager.default.removeItem(at: audio)
        try store.delete(id: record.id)
        XCTAssertNil(try store.fetch(id: record.id))
    }

    func testConcurrentCallersCanAppendAndRead() async throws {
        let store = try XCTUnwrap(store)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let record = try store.append(rawText: "concurrent entry \(index)")
                    let fetched = try XCTUnwrap(store.fetch(id: record.id))
                    XCTAssertEqual(fetched, record)
                    return record.id
                }
            }
            var ids: Set<UUID> = []
            for try await id in group { ids.insert(id) }
            return ids
        }
        XCTAssertEqual(ids.count, 50)
        XCTAssertEqual(Set(try store.listRecent(limit: 100).map(\.id)), ids)
        XCTAssertEqual(Set(try store.search("concurrent", limit: 100).map(\.id)), ids)
    }

    private func reopen() throws {
        try store.close()
        store = try MemoryStore(directory: directory)
    }
}
