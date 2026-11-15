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
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            for word in words {
                XCTAssertNil(data.range(of: Data(word.utf8)), "Retained \(word) in \(file.lastPathComponent)")
            }
        }
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
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            XCTAssertNoThrow(try db.execute(sql: """
                INSERT INTO records (id, deviceID, kind, createdAt, rawText, finalText)
                VALUES (?, ?, 'futureKind', 100, 'future', 'future')
                """, arguments: [UUID().uuidString, store.deviceID.uuidString]))
        }
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

    private func reopen() throws {
        try store.close()
        store = try MemoryStore(directory: directory)
    }
}
