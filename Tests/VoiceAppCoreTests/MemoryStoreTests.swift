import Darwin
import Foundation
import GRDB
import SQLite3
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
            modelID: "whisper-tiny", durationSeconds: 3.25, audioExtension: "wav"
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
        let record = try store.append(
            rawText: "private original", finalText: "private correction", appBundleID: "com.example.editor",
            appName: "Editor", project: "Secret", modelID: "model", durationSeconds: 2,
            audioExtension: "wav"
        )
        let audio = try XCTUnwrap(store.audioURL(for: record))
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audio)
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
        let record = try store.append(rawText: "already removed", audioExtension: "wav")
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
        let unknown = UUID()
        try store.delete(id: unknown)
        XCTAssertNil(try store.tombstone(id: unknown))
    }

    func testHostileSearchInputIsLiteralAndNeverBecomesFTSSyntax() throws {
        let record = try store.append(rawText: "alpha beta")
        let prefix = try store.append(rawText: "alphabet")
        for query in [
            "\"alpha", "alpha\"", "alpha*", "-alpha", "{alpha}", "(alpha", "alpha)", "[alpha]",
            "alpha***", "alpha\\", "alpha;", "alpha!", "alpha?", "alpha/", "alpha+", "alpha=",
            "alpha@", "alpha#", "alpha$", "alpha%", "alpha^", "alpha&", "alpha|",
        ] {
            XCTAssertEqual(try store.search(query), [prefix, record], query)
        }
        for query in ["alpha:beta", "alpha - beta", "alpha bet*", "\"alpha beta\"", "alpha(beta)"] {
            XCTAssertEqual(try store.search(query), [record], query)
        }
        for query in [
            "", " ", "\t\n", "\"", "*", "-", ":", "\"*-:", "😀", "\0", "alpha OR beta", "alpha AND beta",
            "rawText:alpha", "finalText:alpha", "NEAR(alpha beta)", "NEAR(alpha beta, 2)", "alpha NOT beta",
            "') OR 1=1 --", "alpha UNION SELECT", "alpha; DROP TABLE records;--", "alpha OR alphabet",
            "alpha NOT alphabet", "alpha AND alphabet", "\" OR \"", "alpha missing*",
            String(repeating: "missing ", count: 2_000),
        ] {
            XCTAssertEqual(try store.search(query), [], query)
        }
        let operators = try store.append(rawText: "alpha OR beta")
        XCTAssertEqual(try store.search("alpha OR beta"), [operators])
    }

    func testAudioExtensionsAreShortASCIIAlphanumeric() throws {
        for ext in ["", ".wav", "../wav", "/tmp/wav", "audio/wav", "w av", "w\0av", "w-av", "w_av", "é", "e\u{301}", "12345678901"] {
            XCTAssertThrowsError(try store.append(rawText: "invalid", audioExtension: ext), ext) { error in
                XCTAssertEqual(error as? MemoryStore.StoreError, .invalidAudioExtension)
            }
        }
        XCTAssertEqual(try store.listRecent(), [])
        let record = try store.append(rawText: "valid", audioExtension: "Wav24")
        XCTAssertEqual(record.audioPath, "audio/\(record.id.uuidString).wav24")
        XCTAssertNil(try store.audioURL(for: store.append(rawText: "no audio")))
    }

    func testFailedAudioDeletionKeepsRecordAvailableForRetry() throws {
        let record = try store.append(rawText: "keep until removed", audioExtension: "wav")
        let audio = try XCTUnwrap(store.audioURL(for: record))
        let folder = audio.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audio)
        XCTAssertEqual(chmod(folder.path, 0o555), 0)
        defer { chmod(folder.path, 0o755) }
        XCTAssertThrowsError(try store.delete(id: record.id)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
        XCTAssertEqual(try store.fetch(id: record.id), record)
        XCTAssertNil(try store.tombstone(id: record.id))
        XCTAssertEqual(try store.search("keep"), [record])
        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        try store.delete(id: record.id)
        XCTAssertNil(try store.fetch(id: record.id))
        XCTAssertNotNil(try store.tombstone(id: record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
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

    func testDeletedWordsAreAbsentFromEveryStoreFileAfterClose() throws {
        let words = ["saffronquartz", "velvetbadger", "cobaltmeadow"]
        let record = try store.append(rawText: words[0], finalText: words[1], project: words[2])
        _ = try store.append(rawText: "surviving searchable text")
        try store.delete(id: record.id)
        try store.close()
        store = nil
        try assertNoDeletedWords(in: words)
    }

    func testTwoInstancesPreserveAllConcurrentAppends() async throws {
        let first = try XCTUnwrap(store)
        let second = try MemoryStore(directory: directory)
        defer { try? second.close() }
        let results = await withTaskGroup(of: Result<UUID, Error>.self) { group in
            for index in 0..<200 {
                group.addTask {
                    Result { try (index.isMultiple(of: 2) ? first : second).append(rawText: "shared entry \(index)").id }
                }
            }
            var results: [Result<UUID, Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        let ids = results.compactMap { try? $0.get() }
        XCTAssertEqual(ids.count, 200, "Failed writes: \(results.count - ids.count)")
        XCTAssertEqual(Set(try first.listRecent(limit: 300).map(\.id)), Set(ids))
        XCTAssertEqual(try second.search("shared", limit: 300).count, 200)
    }

    func testSimultaneousFirstOpensShareIdentityAndPreserveWrites() async throws {
        let fresh = directory.appending(path: "fresh")
        let results = await withTaskGroup(of: Result<UUID, Error>.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    Result {
                        let instance = try MemoryStore(directory: fresh)
                        defer { try? instance.close() }
                        try instance.append(rawText: "first open")
                        return instance.deviceID
                    }
                }
            }
            var results: [Result<UUID, Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        for result in results {
            if case .failure(let error) = result { XCTFail("First open failed: \(error)") }
        }
        let ids = results.compactMap { try? $0.get() }
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(Set(ids).count, 1)
        let instance = try MemoryStore(directory: fresh)
        defer { try? instance.close() }
        XCTAssertEqual(try instance.listRecent().count, 8)
    }

    func testEqualTimestampsUseReverseInsertionOrder() throws {
        let records = try (0..<12).map { _ in
            try store.append(createdAt: Date(timeIntervalSince1970: 100), rawText: "same timestamp")
        }
        try reopen()
        XCTAssertEqual(try store.listRecent(), records.reversed())
        XCTAssertEqual(try store.search("same"), records.reversed())
    }

    func testInvalidDurationsAreRejectedWithoutInserting() throws {
        for duration in [-1.0, -.infinity, .infinity, .nan] {
            XCTAssertThrowsError(try store.append(rawText: "invalid duration", durationSeconds: duration)) { error in
                XCTAssertEqual(error as? MemoryStore.StoreError, .invalidDuration)
            }
        }
        XCTAssertEqual(try store.listRecent(), [])
        for duration in [0.0, 2.5] {
            XCTAssertEqual(try store.append(rawText: "valid", durationSeconds: duration).durationSeconds, duration)
        }
    }

    func testSchemaAllowsFutureKindsWithoutRebuildingTable() throws {
        let known = try store.append(rawText: "future compatible")
        let id = UUID()
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO records (id, deviceID, kind, createdAt, rawText, finalText)
                VALUES (?, ?, 'journal', 100, 'future journal', 'future journal')
                """, arguments: [id.uuidString, store.deviceID.uuidString])
        }
        let future = try XCTUnwrap(store.fetch(id: id))
        XCTAssertEqual(future.kind.rawValue, "journal")
        XCTAssertEqual(try store.listRecent(), [known, future])
        XCTAssertEqual(try store.search("future"), [known, future])
        XCTAssertEqual(try store.listRecent(kind: future.kind), [future])
        XCTAssertEqual(try store.search("future", kind: future.kind), [future])
        let copy = try JSONDecoder().decode(MemoryRecord.self, from: JSONEncoder().encode(future))
        XCTAssertEqual(copy, future)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(future.kind), as: UTF8.self), "\"journal\"")
        try reopen()
        XCTAssertEqual(try store.fetch(id: id), future)
        XCTAssertEqual(try database.read { db in
            try String.fetchOne(db, sql: "SELECT kind FROM records WHERE id = ?", arguments: [id.uuidString])
        }, "journal")
    }

    func testSchemaRejectsContentUpdatesAndTombstoneResurrection() throws {
        let record = try store.append(rawText: "immutable")
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            for assignment in [
                "rawText = 'edited'", "finalText = 'edited'", "id = 'replacement'", "deviceID = 'replacement'",
                "kind = 'note'", "createdAt = 0", "audioPath = 'other.wav'", "rowid = rowid + 100",
            ] {
                XCTAssertThrowsError(try db.execute(sql: "UPDATE records SET \(assignment) WHERE id = ?", arguments: [record.id.uuidString]))
            }
        }
        XCTAssertEqual(try store.fetch(id: record.id), record)
        try store.delete(id: record.id)
        let tombstone = try store.tombstone(id: record.id)
        try database.write { db in
            XCTAssertThrowsError(try db.execute(sql: "UPDATE records SET deletedAt = deletedAt + 1 WHERE id = ?", arguments: [record.id.uuidString]))
            XCTAssertThrowsError(try db.execute(sql: """
                UPDATE records SET deletedAt = NULL, kind = 'dictation', createdAt = 100,
                    rawText = 'resurrected', finalText = 'resurrected' WHERE id = ?
                """, arguments: [record.id.uuidString]))
        }
        XCTAssertEqual(try store.tombstone(id: record.id), tombstone)
    }

    func testSearchUsesOnlyTheLastWordAsAPrefix() throws {
        let record = try store.append(rawText: "visit München tomorrow")
        let other = try store.append(rawText: "visiting München")
        XCTAssertEqual(try store.search("Mün"), [other, record])
        XCTAssertEqual(try store.search("visit Mün"), [record])
        XCTAssertEqual(try store.search("visi München"), [])
    }

    func testSymlinkAtAudioPathDoesNotBlockDeletionOrRemoveTarget() throws {
        let record = try store.append(rawText: "delete safely", audioExtension: "wav")
        let target = directory.deletingLastPathComponent().appending(path: UUID().uuidString)
        try Data("outside".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let audio = try XCTUnwrap(store.audioURL(for: record))
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: target)
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
        XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testAudioLocationsAreDerivedFromRecordIDs() throws {
        let first = try store.append(rawText: "first", audioExtension: "wav")
        let second = try store.append(rawText: "second", audioExtension: "WAV")
        XCTAssertEqual(first.audioPath, "audio/\(first.id.uuidString).wav")
        XCTAssertEqual(second.audioPath, "audio/\(second.id.uuidString).wav")
        let firstURL = try XCTUnwrap(store.audioURL(for: first))
        let secondURL = try XCTUnwrap(store.audioURL(for: second))
        XCTAssertNotEqual(firstURL, secondURL)
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        try store.delete(id: first.id)
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("second".utf8))
        XCTAssertEqual(try store.fetch(id: second.id), second)
    }

    func testUnexpectedAudioObjectsDoNotBlockTombstones() throws {
        let record = try store.append(rawText: "unexpected directory", audioExtension: "wav")
        let audio = try XCTUnwrap(store.audioURL(for: record))
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let child = audio.appending(path: "keep")
        try Data("unexpected contents".utf8).write(to: child)
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
        XCTAssertEqual(try Data(contentsOf: child), Data("unexpected contents".utf8))
    }

    func testAudioFolderSymlinkCannotRedirectDeletion() throws {
        let record = try store.append(rawText: "safe parent", audioExtension: "wav")
        let audio = try XCTUnwrap(store.audioURL(for: record))
        let outside = directory.deletingLastPathComponent().appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appending(path: audio.lastPathComponent)
        try Data("outside audio".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: audio.deletingLastPathComponent(), withDestinationURL: outside)
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
        XCTAssertEqual(try Data(contentsOf: target), Data("outside audio".utf8))
    }

    func testUnremovableDanglingAudioSymlinkDoesNotBlockTombstone() throws {
        let record = try store.append(rawText: "dangling link", audioExtension: "wav")
        let audio = try XCTUnwrap(store.audioURL(for: record))
        let folder = audio.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: directory.appending(path: "absent"))
        XCTAssertEqual(chmod(folder.path, 0o555), 0)
        defer { chmod(folder.path, 0o755) }
        try store.delete(id: record.id)
        XCTAssertNotNil(try store.tombstone(id: record.id))
    }

    func testReopenEnablesFTSSecureDeleteForExistingDatabase() throws {
        guard sqlite3_libversion_number() >= 3_042_000 else {
            throw XCTSkip("FTS5 secure-delete requires SQLite 3.42+")
        }
        let record = try store.append(rawText: "upgrade survivor")
        try store.close()
        store = nil
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        try database.write { db in
            try db.execute(sql: "INSERT INTO recordsFTS(recordsFTS, rank) VALUES('secure-delete', 0)")
        }
        try database.close()
        store = try MemoryStore(directory: directory)
        XCTAssertEqual(try store.fetch(id: record.id), record)
        let check = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? check.close() }
        XCTAssertEqual(try check.read { db in
            try Int.fetchOne(db, sql: "SELECT v FROM recordsFTS_config WHERE k = 'secure-delete'")
        }, 1)
    }

    func testDeleteScrubsShrunkenIndexAfterLongNote() throws {
        let words = ["saffronquartz", "velvetbadger", "cobaltmeadow"]
        let note = try store.append(kind: .note, rawText: (0..<300).map { words[$0 % words.count] }.joined(separator: " "))
        let dictations = try (0..<3).map { _ in try store.append(rawText: "surviving searchable text") }
        try store.delete(id: dictations[0].id)
        try store.delete(id: dictations[1].id)
        try store.delete(id: note.id)
        let secret = try store.append(rawText: "my bank pin is quokkasecret")
        try store.delete(id: secret.id)
        XCTAssertEqual(try store.listRecent(), [dictations[2]])
        try store.close()
        store = nil
        try assertNoDeletedWords(in: words + ["quokkasecret"])
    }

    func testDeleteScrubsClearedHistoryAndSubsequentSecret() throws {
        let words = distinctiveWords(count: 197)
        let records = try words.map { try store.append(rawText: $0) }
        let survivors = try (0..<3).map { _ in try store.append(rawText: "surviving searchable text") }
        for record in records { try store.delete(id: record.id) }
        let secretWords = ["quokkasecret", "zebracanary"]
        let secret = try store.append(rawText: "zdaxw " + secretWords.joined(separator: " "))
        try store.delete(id: secret.id)
        XCTAssertEqual(try store.listRecent(), survivors.reversed())
        try store.close()
        store = nil
        try assertNoDeletedWords(in: words + secretWords)
    }

    func testSchemaRejectsReplacementAndDeletionOfLiveRecordsAndTombstones() throws {
        let live = try store.append(rawText: "live original")
        let deleted = try store.append(rawText: "deleted original")
        try store.delete(id: deleted.id)
        let tombstone = try store.tombstone(id: deleted.id)
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            // REPLACE must be rejected even on connections that do not fire recursive delete triggers.
            try db.execute(sql: "PRAGMA recursive_triggers = OFF")
            for record in [live, deleted] {
                XCTAssertThrowsError(try record.insert(db)) { error in
                    XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
                }
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT OR REPLACE INTO records (id, deviceID, kind, createdAt, rawText, finalText)
                    VALUES (?, ?, 'note', 100, 'replacement', 'replacement')
                    """, arguments: [record.id.uuidString, record.deviceID.uuidString]))
                XCTAssertThrowsError(try record.insert(db, onConflict: .replace))
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT OR REPLACE INTO records (rowid, id, deviceID, kind, createdAt, rawText, finalText)
                    SELECT rowid, ?, deviceID, 'note', 100, 'replacement', 'replacement' FROM records WHERE id = ?
                    """, arguments: [UUID().uuidString, record.id.uuidString]))
                XCTAssertThrowsError(try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [record.id.uuidString]))
            }
        }
        XCTAssertEqual(try store.fetch(id: live.id), live)
        XCTAssertEqual(try store.tombstone(id: deleted.id), tombstone)
        XCTAssertEqual(try store.search("original"), [live])
        XCTAssertEqual(try store.search("replacement"), [])
    }

    func testMalformedStoredAudioPathsDoNotBlockTombstonesOrRemoveOtherFiles() throws {
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        for path in ["audio/clip", "audio/clip.bad-ext", "audio/other.wav", "../outside.wav"] {
            let id = UUID()
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO records (id, deviceID, kind, createdAt, rawText, finalText, audioPath)
                    VALUES (?, ?, 'dictation', 100, 'malformed audio', 'malformed audio', ?)
                    """, arguments: [id.uuidString, store.deviceID.uuidString, path])
            }
            let decoy = directory.appending(path: "audio/\(id.uuidString).wav")
            try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: decoy)
            XCTAssertNil(try store.audioURL(for: XCTUnwrap(store.fetch(id: id))))
            XCTAssertNoThrow(try store.delete(id: id))
            XCTAssertNotNil(try store.tombstone(id: id))
            XCTAssertEqual(try Data(contentsOf: decoy), Data("keep".utf8))
        }
    }

    func testMigrationLockTimesOutAndCanBeRetriedAfterRelease() throws {
        let lock = open(directory.appending(path: "store.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { Darwin.close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let timedOut = expectation(description: "open times out with typed error")
        let finished = expectation(description: "open returns")
        let directory = try XCTUnwrap(directory)
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                let blocked = try MemoryStore(directory: directory)
                try blocked.close()
                XCTFail("Open returned without a migration-lock timeout")
            } catch {
                XCTAssertEqual(error as? MemoryStore.StoreError, .migrationLockTimeout)
                timedOut.fulfill()
            }
        }
        wait(for: [timedOut], timeout: 7)
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        wait(for: [finished], timeout: 2)
        let retry = try MemoryStore(directory: directory)
        defer { try? retry.close() }
        XCTAssertEqual(retry.deviceID, store.deviceID)
    }

    func testSchemaRejectsNoncanonicalRecordIDs() throws {
        let record = try store.append(rawText: "canonical")
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            let ids: [any DatabaseValueConvertible] = [
                record.id.uuidString.lowercased(), record.id.uuidString + "\0suffix", Data(record.id.uuidString.utf8),
                "not-a-uuid", String(repeating: "G", count: 36),
                "01234567-89AB-CDEF-0123-456789ABCDEG", "0123456789AB-CDEF-0123-456789ABCDEF-",
            ]
            for id in ids {
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT INTO records (id, deviceID, kind, createdAt, rawText, finalText)
                    VALUES (?, ?, 'dictation', 100, 'duplicate', 'duplicate')
                    """, arguments: [id, store.deviceID.uuidString])) { error in
                    XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
                }
            }
        }
        XCTAssertEqual(try store.listRecent(), [record])
    }

    private func distinctiveWords(count: Int) -> [String] {
        var state: UInt64 = 0x12345678
        return (0..<count).map { _ in
            String((0..<24).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Character(UnicodeScalar(97 + Int((state >> 32) % 26))!)
            })
        }
    }

    private func assertNoDeletedWords(in words: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        // Every longer residue contains a six-byte window, including prefix-compressed suffixes.
        let fragments = Set(words.flatMap { word -> [Data] in
            let bytes = Array(word.utf8)
            guard bytes.count >= 6 else { return [] }
            return (0...(bytes.count - 6)).map { Data(bytes[$0..<($0 + 6)]) }
        })
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            let retained = fragments.filter { data.range(of: $0) != nil }
            XCTAssertTrue(retained.isEmpty, "Retained \(retained.count) deleted fragments in \(url.lastPathComponent): \(retained.prefix(5).map { String(decoding: $0, as: UTF8.self) })", file: file, line: line)
        }
    }

    private func reopen() throws {
        try store.close()
        store = try MemoryStore(directory: directory)
    }
}
