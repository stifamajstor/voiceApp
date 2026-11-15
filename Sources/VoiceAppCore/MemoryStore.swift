import Darwin
import Foundation
import GRDB
import SQLite3

public final class MemoryStore: Sendable {
    public enum StoreError: Error, Equatable {
        case invalidAudioExtension
        case invalidDuration
        case missingDeviceID
        case migrationLockTimeout
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VoiceApp/store", directoryHint: .isDirectory)
    }

    public let directory: URL
    public let deviceID: UUID
    private let database: DatabaseQueue

    public init(directory: URL = MemoryStore.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        // GRDB reads migration state before taking its write lock, so first opens must serialize migrations.
        let migrationLock = open(self.directory.appending(path: "store.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard migrationLock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(migrationLock) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while flock(migrationLock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard ContinuousClock.now < deadline else { throw StoreError.migrationLockTimeout }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        database = try DatabaseQueue(path: self.directory.appending(path: "store.sqlite").path, configuration: configuration)
        try Self.migrator.migrate(database)
        if sqlite3_libversion_number() >= 3_042_000 {
            // Configure on every open so stores created before an OS upgrade also scrub FTS entries.
            try database.write { db in
                try db.execute(sql: "INSERT INTO recordsFTS(recordsFTS, rank) VALUES('secure-delete', 1)")
            }
        }
        deviceID = try database.read { db in
            guard let id = try UUID.fetchOne(db, sql: "SELECT deviceID FROM storeMetadata WHERE singleton = 1")
            else { throw StoreError.missingDeviceID }
            return id
        }
    }

    public func close() throws {
        try database.close()
    }

    @discardableResult
    public func append(
        kind: RecordKind = .dictation,
        createdAt: Date = .now,
        rawText: String,
        finalText: String? = nil,
        appBundleID: String? = nil,
        appName: String? = nil,
        project: String? = nil,
        modelID: String? = nil,
        durationSeconds: Double? = nil,
        audioExtension: String? = nil
    ) throws -> MemoryRecord {
        if let durationSeconds, !durationSeconds.isFinite || durationSeconds < 0 {
            throw StoreError.invalidDuration
        }
        let id = UUID()
        let audioPath = try audioExtension.map { "audio/\(id.uuidString).\(try Self.validatedAudioExtension($0))" }
        // Match the timestamp precision restored from SQLite's Unix-epoch REAL.
        let record = MemoryRecord(
            id: id, deviceID: deviceID, kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt.timeIntervalSince1970),
            rawText: rawText, finalText: finalText ?? rawText, appBundleID: appBundleID,
            appName: appName, project: project, modelID: modelID,
            durationSeconds: durationSeconds, audioPath: audioPath, deletedAt: nil
        )
        return try database.write { db in
            try record.insert(db)
            return record
        }
    }

    public func fetch(id: UUID) throws -> MemoryRecord? {
        try database.read { db in
            try MemoryRecord.fetchOne(db,
                sql: "SELECT * FROM records WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString])
        }
    }

    public func listRecent(kind: RecordKind? = nil, limit: Int = 50) throws -> [MemoryRecord] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            try MemoryRecord.fetchAll(db, sql: """
                SELECT * FROM records
                WHERE deletedAt IS NULL AND (? IS NULL OR kind = ?)
                ORDER BY createdAt DESC, records.rowid DESC LIMIT ?
                """, arguments: [kind?.rawValue, kind?.rawValue, limit])
        }
    }

    public func search(_ query: String, kind: RecordKind? = nil, limit: Int = 50) throws -> [MemoryRecord] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            let tokens = try db.makeTokenizer(.unicode61()).tokenize(query: query)
            guard !tokens.isEmpty else { return [] }
            // Quoting tokens prevents typed text from becoming FTS operators or column selectors.
            let pattern = tokens.enumerated().map { index, token in
                let quoted = "\"" + token.token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                return quoted + (index == tokens.count - 1 ? "*" : "")
            }.joined(separator: " AND ")
            return try MemoryRecord.fetchAll(db, sql: """
                SELECT records.* FROM records
                JOIN recordsFTS ON recordsFTS.rowid = records.rowid
                WHERE recordsFTS MATCH ? AND deletedAt IS NULL AND (? IS NULL OR kind = ?)
                ORDER BY createdAt DESC, records.rowid DESC LIMIT ?
                """, arguments: [pattern, kind?.rawValue, kind?.rawValue, limit])
        }
    }

    public func tombstone(id: UUID) throws -> RecordTombstone? {
        try database.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT id, deviceID, deletedAt FROM records WHERE id = ? AND deletedAt IS NOT NULL",
                arguments: [id.uuidString]) else { return nil }
            return RecordTombstone(id: row["id"], deviceID: row["deviceID"], deletedAt: row["deletedAt"])
        }
    }

    public func delete(id: UUID) throws {
        try database.write { db in
            guard let record = try MemoryRecord.fetchOne(db,
                sql: "SELECT * FROM records WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString]) else { return }
            if let audio = try audioURL(for: record) {
                try removeAudio(at: audio)
            }
            try db.execute(sql: """
                UPDATE records SET kind = NULL, createdAt = NULL, rawText = NULL, finalText = NULL,
                    appBundleID = NULL, appName = NULL, project = NULL, modelID = NULL,
                    durationSeconds = NULL, audioPath = NULL, deletedAt = ?
                WHERE id = ?
                """, arguments: [Date.now.timeIntervalSince1970, id.uuidString])
            if sqlite3_libversion_number() < 3_042_000 {
                // Older FTS5 retains deleted tokens in live segments; only rebuilding reliably removes them.
                try db.execute(sql: "INSERT INTO recordsFTS(recordsFTS) VALUES('rebuild')")
            }
        }
    }

    public func audioURL(for record: MemoryRecord) throws -> URL? {
        guard let path = record.audioPath,
              let ext = try? Self.validatedAudioExtension((path as NSString).pathExtension),
              path == "audio/\(record.id.uuidString).\(ext)" else { return nil }
        return directory.appending(path: path)
    }

    private static func validatedAudioExtension(_ value: String) throws -> String {
        guard (1...10).contains(value.utf8.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { throw StoreError.invalidAudioExtension }
        return value.lowercased()
    }

    private func removeAudio(at url: URL) throws {
        // Directory descriptors prevent a replaced audio folder from redirecting deletion outside the store.
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(root) }
        let audio = openat(root, "audio", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard audio >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(audio) }
        var info = stat()
        let name = url.lastPathComponent
        guard fstatat(audio, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else { return }
        guard unlinkat(audio, name, 0) == 0 else {
            if type == S_IFLNK || errno == ENOENT || errno == EISDIR { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("memoryStore.createRecords") { db in
            try db.execute(sql: """
                CREATE TABLE storeMetadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    deviceID TEXT NOT NULL
                );
                CREATE TABLE records (
                    id TEXT PRIMARY KEY NOT NULL CHECK (
                        typeof(id) = 'text' AND length(CAST(id AS BLOB)) = 36
                        AND length(replace(id, '-', '')) = 32
                        AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-'
                        AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-'
                        AND id NOT GLOB '*[^0-9A-F-]*'
                    ),
                    deviceID TEXT NOT NULL,
                    kind TEXT,
                    createdAt REAL,
                    rawText TEXT,
                    finalText TEXT,
                    appBundleID TEXT,
                    appName TEXT,
                    project TEXT,
                    modelID TEXT,
                    durationSeconds REAL,
                    audioPath TEXT,
                    deletedAt REAL,
                    CHECK (
                        (deletedAt IS NULL AND kind IS NOT NULL AND createdAt IS NOT NULL
                            AND rawText IS NOT NULL AND finalText IS NOT NULL)
                        OR (deletedAt IS NOT NULL AND kind IS NULL AND createdAt IS NULL
                            AND rawText IS NULL AND finalText IS NULL AND appBundleID IS NULL
                            AND appName IS NULL AND project IS NULL AND modelID IS NULL
                            AND durationSeconds IS NULL AND audioPath IS NULL)
                    )
                );
                CREATE TRIGGER records_no_replace BEFORE INSERT ON records
                WHEN EXISTS (SELECT 1 FROM records WHERE id = NEW.id OR rowid = NEW.rowid)
                BEGIN
                    SELECT RAISE(ABORT, 'records cannot be replaced');
                END;
                CREATE TRIGGER records_no_delete BEFORE DELETE ON records
                BEGIN
                    SELECT RAISE(ABORT, 'records must be retained as tombstones');
                END;
                CREATE TRIGGER records_immutable BEFORE UPDATE ON records
                WHEN OLD.deletedAt IS NOT NULL OR NEW.deletedAt IS NULL
                    OR NEW.id IS NOT OLD.id OR NEW.deviceID IS NOT OLD.deviceID
                    OR NEW.rowid IS NOT OLD.rowid
                BEGIN
                    SELECT RAISE(ABORT, 'records can only transition to tombstones');
                END;
                CREATE INDEX records_recent ON records (createdAt) WHERE deletedAt IS NULL;
                """)
            try db.execute(sql: "INSERT INTO storeMetadata (singleton, deviceID) VALUES (1, ?)",
                arguments: [UUID().uuidString])
        }
        migrator.registerMigration("memoryStore.indexRecordText") { db in
            try db.create(virtualTable: "recordsFTS", using: FTS5()) { table in
                table.synchronize(withTable: "records")
                table.tokenizer = .unicode61()
                table.column("rawText")
                table.column("finalText")
            }
        }
        return migrator
    }
}
