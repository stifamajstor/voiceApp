import Darwin
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
        XCTAssertNil(store.audioURL(for: try store.append(rawText: "no audio")))
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
                        var configuration = Configuration()
                        configuration.busyMode = .timeout(5)
                        let database = try DatabaseQueue(path: fresh.appending(path: "store.sqlite").path, configuration: configuration)
                        defer { try? database.close() }
                        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") }, 1)
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

    func testSecureDeletePragmaScrubsLongNotePayload() throws {
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
                    XCTAssertEqual((error as? DatabaseError)?.extendedResultCode, .SQLITE_CONSTRAINT_TRIGGER)
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
            XCTAssertNil(store.audioURL(for: try XCTUnwrap(store.fetch(id: id))))
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

    func testBatchDeletePreservesTombstonesAndSurvivors() throws {
        let records = try (0..<1_005).map { _ in try store.append(rawText: "batch secret") }
        let survivor = try store.append(rawText: "survivor")
        try store.delete(ids: records.map(\.id) + [records[0].id, UUID()])
        try store.delete(ids: [])
        try reopen()
        XCTAssertEqual(try store.listRecent(), [survivor])
        XCTAssertEqual(try store.search("batch"), [])
        for record in records {
            let tombstone = try XCTUnwrap(store.tombstone(id: record.id))
            XCTAssertEqual(tombstone.id, record.id)
            XCTAssertEqual(tombstone.deviceID, record.deviceID)
        }
        let before = try store.tombstone(id: records[0].id)
        try store.delete(ids: records.map(\.id))
        XCTAssertEqual(try store.tombstone(id: records[0].id), before)
    }

    func testBatchDeleteRollsBackAllTombstonesOnFailure() throws {
        let first = try store.append(rawText: "first original")
        let second = try store.append(rawText: "second original")
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_second_delete BEFORE UPDATE ON records
                WHEN OLD.id = '\(second.id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END
                """)
        }
        XCTAssertThrowsError(try store.delete(ids: [first.id, second.id]))
        XCTAssertEqual(try store.fetch(id: first.id), first)
        XCTAssertEqual(try store.fetch(id: second.id), second)
        XCTAssertNil(try store.tombstone(id: first.id))
        XCTAssertEqual(try store.search("original"), [second, first])
    }

    func testAudioURLCanBeUsedWithoutThrowing() throws {
        let record = try store.append(rawText: "audio", audioExtension: "wav")
        let location: (MemoryRecord) -> URL? = store.audioURL(for:)
        XCTAssertEqual(location(record), directory.appending(path: "audio/\(record.id.uuidString).wav"))
    }

    func testDeleteRemovesDeadIndexKeysAndTermsAcrossLeafPages() throws {
        let words = distinctiveWords(count: 5_760)
        let records = try (0..<240).map { index in
            try store.append(rawText: words[(index * 24)..<((index + 1) * 24)].joined(separator: " "))
        }
        let deleted = records.enumerated().filter { ($0.offset * 73 % 240) < 120 }
        let deletedWords = deleted.flatMap { words[($0.offset * 24)..<(($0.offset + 1) * 24)] }
        let liveWords = Set(words).subtracting(deletedWords)
        for (_, record) in deleted { try store.delete(id: record.id) }
        try store.close()
        store = nil

        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        try database.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.liveTerms USING fts5vocab(main, recordsFTS, row)")
            let terms = try Set(String.fetchAll(db, sql: "SELECT term FROM liveTerms"))
            XCTAssertEqual(terms, liveWords)
            let keys = try Data.fetchAll(db, sql: "SELECT term FROM recordsFTS_idx WHERE length(term) > 0")
            XCTAssertGreaterThan(keys.count, 10, "Fixture must span many index leaf pages")
            for key in keys {
                // FTS5 prepends the index number ('0' for the main token index).
                XCTAssertEqual(key.first, Character("0").asciiValue)
                let prefix = String(decoding: key.dropFirst(), as: UTF8.self)
                XCTAssertTrue(terms.contains { $0.hasPrefix(prefix) }, "Dead index key: \(prefix)")
            }
        }
        try database.close()
        // Wider byte windows avoid accidental overlaps in this corpus; the key check covers short prefixes.
        try assertNoDeletedWords(in: Array(deletedWords), excluding: Array(liveWords), windowLength: 8)
    }

    func testFreshStoreTruncatesFreePagesOnEveryCommit() throws {
        XCTAssertEqual(try autoVacuumMode(), 1)
        _ = try store.append(rawText: "first")
        XCTAssertEqual(try autoVacuumMode(), 1)
        try reopen()
        XCTAssertEqual(try autoVacuumMode(), 1)
        let second = try MemoryStore(directory: directory)
        defer { try? second.close() }
        XCTAssertEqual(try autoVacuumMode(), 1)
    }

    func testOpenDoesNotWaitForAnotherConnectionsWriteLock() throws {
        let record = try store.append(rawText: "still readable")
        let writer = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? writer.close() }
        try writer.inDatabase { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            defer { try? db.execute(sql: "ROLLBACK") }
            let start = ContinuousClock.now
            let reader = try MemoryStore(directory: directory)
            defer { try? reader.close() }
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
            XCTAssertEqual(try reader.listRecent(), [record])
        }
    }

    func testExistingReadOnlyDatabaseCanOpen() throws {
        let record = try store.append(rawText: "read only")
        try store.close()
        store = nil
        let path = directory.appending(path: "store.sqlite").path
        XCTAssertEqual(chmod(path, 0o444), 0)
        defer { chmod(path, 0o600) }
        let reader = try MemoryStore(directory: directory)
        defer { try? reader.close() }
        XCTAssertEqual(try reader.listRecent(), [record])
    }

    func testDeletesLeaveNoFreePages() throws {
        let single = try (0..<40).map { _ in try store.append(rawText: String(repeating: "freepage filler ", count: 200)) }
        let batch = try (0..<400).map { _ in try store.append(rawText: String(repeating: "batch filler ", count: 50)) }
        try store.delete(id: single[0].id)
        try store.delete(ids: batch.map(\.id) + single.dropFirst().map(\.id))
        try store.close()
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "PRAGMA freelist_count") }, 0)
    }

    func testSchemaRejectsBlobKindsAndNoncanonicalDeviceIDs() throws {
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            let invalid: [(any DatabaseValueConvertible, any DatabaseValueConvertible)] = [
                (Data("note".utf8), store.deviceID.uuidString),
                ("note", "not-a-uuid"), ("note", store.deviceID.uuidString.lowercased()),
                ("note", Data(store.deviceID.uuidString.utf8)),
                ("note", store.deviceID.uuidString + "\0suffix"),
                ("note", "0123456789AB-CDEF-0123-456789ABCDEF-"),
            ]
            for (kind, deviceID) in invalid {
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT INTO records (id, deviceID, kind, createdAt, rawText, finalText)
                    VALUES (?, ?, ?, 100, 'foreign', 'foreign')
                    """, arguments: [UUID().uuidString, deviceID, kind])) { error in
                    XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
                }
            }
        }
        let record = try store.append(rawText: "healthy")
        XCTAssertEqual(try store.listRecent(), [record])
        XCTAssertEqual(try store.search("healthy"), [record])
        XCTAssertNoThrow(try store.delete(id: record.id))
    }

    func testSchemaRejectsNonnumericDeletionDates() throws {
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            for date: any DatabaseValueConvertible in ["yesterday", Data([1, 2, 3])] {
                XCTAssertThrowsError(try db.execute(sql: "INSERT INTO records (id, deviceID, deletedAt) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, store.deviceID.uuidString, date]))
            }
        }
    }

    func testMalformedTombstoneDateThrowsInsteadOfCrashing() throws {
        let id = UUID()
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            // Simulate a corrupt or externally written database, bypassing the schema guard.
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: "INSERT INTO records (id, deviceID, deletedAt) VALUES (?, ?, 'yesterday')",
                arguments: [id.uuidString, store.deviceID.uuidString])
        }
        XCTAssertThrowsError(try store.tombstone(id: id)) { error in
            XCTAssertTrue(error is RowDecodingError)
        }
    }

    func testSchemaRejectsNonpositiveRowIDsWithoutBlockingAppends() throws {
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            for rowid in [-1, 0, -2] {
                XCTAssertThrowsError(try db.execute(sql: """
                    INSERT INTO records (rowid, id, deviceID, kind, createdAt, rawText, finalText)
                    VALUES (?, ?, ?, 'note', 100, 'foreign', 'foreign')
                    """, arguments: [rowid, UUID().uuidString, store.deviceID.uuidString]))
            }
        }
        let record = try store.append(rawText: "healthy")
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

    private func assertNoDeletedWords(in words: [String], excluding liveWords: [String] = [], windowLength: Int = 6, file: StaticString = #filePath, line: UInt = #line) throws {
        // Sliding windows also catch prefix-compressed suffixes.
        let mask = UInt64.max >> (64 - windowLength * 8)
        func fragments(in words: [String]) -> Set<UInt64> {
            Set(words.flatMap { word -> [UInt64] in
                var window: UInt64 = 0
                return word.utf8.enumerated().compactMap { index, byte in
                    window = ((window << 8) | UInt64(byte)) & mask
                    return index >= windowLength - 1 ? window : nil
                }
            })
        }
        let deletedFragments = fragments(in: words).subtracting(fragments(in: liveWords))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            var window: UInt64 = 0
            var retained: Set<UInt64> = []
            for (index, byte) in data.enumerated() {
                window = ((window << 8) | UInt64(byte)) & mask
                if index >= windowLength - 1, deletedFragments.contains(window) { retained.insert(window) }
            }
            XCTAssertTrue(retained.isEmpty, "Retained \(retained.count) deleted byte fragments in \(url.lastPathComponent)", file: file, line: line)
        }
    }

    private func autoVacuumMode() throws -> Int? {
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        return try database.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") }
    }

    private func reopen() throws {
        try store.close()
        store = try MemoryStore(directory: directory)
    }
}
