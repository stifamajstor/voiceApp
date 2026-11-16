import Darwin
import Foundation
import GRDB

public final class MemoryStore: Sendable {
    public enum StoreError: LocalizedError, Equatable {
        case invalidAudioExtension
        case invalidDuration
        case missingDeviceID
        case migrationLockTimeout

        public var errorDescription: String? {
            switch self {
            case .invalidAudioExtension:
                return "The audio file extension is invalid."
            case .invalidDuration:
                return "The recording duration must be finite and nonnegative."
            case .missingDeviceID:
                return "The history store is missing its device identity."
            case .migrationLockTimeout:
                return "Timed out waiting for another process to open the history store. Relaunch VoiceApp to try again."
            }
        }
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
            // Setting this on an existing file takes a write lock, even when the mode is unchanged.
            // FULL must be set before migration so free pages are truncated on every commit.
            if try Int.fetchOne(db, sql: "PRAGMA page_count") == 0 {
                try db.execute(sql: "PRAGMA auto_vacuum = FULL")
            }
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        database = try DatabaseQueue(path: self.directory.appending(path: "store.sqlite").path, configuration: configuration)
        try Self.migrator.migrate(database)
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
        id: UUID = UUID(),
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

    public func count(kind: RecordKind) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE kind = ? AND deletedAt IS NULL",
                             arguments: [kind.rawValue]) ?? 0
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
            return try RecordTombstone(id: row.decode(forColumn: "id"), deviceID: row.decode(forColumn: "deviceID"),
                deletedAt: Date(timeIntervalSince1970: row.decode(Double.self, forColumn: "deletedAt")))
        }
    }

    public func delete(id: UUID) throws { try delete(ids: [id]) }

    public func delete(ids: [UUID]) throws {
        try database.write { db in
            var deleted = false
            for id in ids {
                guard let record = try MemoryRecord.fetchOne(db,
                    sql: "SELECT * FROM records WHERE id = ? AND deletedAt IS NULL",
                    arguments: [id.uuidString]) else { continue }
                if let audio = audioURL(for: record) { try removeAudio(at: audio) }
                try db.execute(sql: """
                    UPDATE records SET kind = NULL, createdAt = NULL, rawText = NULL, finalText = NULL,
                        appBundleID = NULL, appName = NULL, project = NULL, modelID = NULL,
                        durationSeconds = NULL, audioPath = NULL, deletedAt = ?
                    WHERE id = ?
                    """, arguments: [Date.now.timeIntervalSince1970, id.uuidString])
                deleted = true
            }
            if deleted {
                // An FTS5 delete leaves the deleted words in the index until a rebuild.
                try db.execute(sql: "INSERT INTO recordsFTS(recordsFTS) VALUES('rebuild')")
            }
        }
    }

    @discardableResult
    public func addTerm(text: String, aliases: [String] = []) throws -> DictionaryTerm {
        let trimmedText = DictionaryTerm.trimEdgeWhitespace(text)
        let trimmedAliases = Self.normalizedAliases(aliases)
        return try database.write { db in
            try Self.validateTerm(text: trimmedText, aliases: trimmedAliases, excluding: nil, in: db)
            let term = DictionaryTerm(text: trimmedText, aliases: trimmedAliases, deviceID: deviceID)
            try term.insert(db)
            return term
        }
    }

    @discardableResult
    public func updateTerm(id: UUID, text: String, aliases: [String]) throws -> DictionaryTerm {
        let trimmedText = DictionaryTerm.trimEdgeWhitespace(text)
        let trimmedAliases = Self.normalizedAliases(aliases)
        return try database.write { db in
            guard var term = try DictionaryTerm.fetchOne(db,
                sql: "SELECT * FROM dictionaryTerms WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString]) else { throw DictionaryError.termNotFound(id) }
            try Self.validateTerm(text: trimmedText, aliases: trimmedAliases, excluding: id, in: db)
            term.text = trimmedText
            term.aliases = trimmedAliases
            term.updatedAt = Self.nextTermDate(after: term.updatedAt)
            term.deviceID = deviceID
            try term.update(db)
            return term
        }
    }

    public func deleteTerm(id: UUID) throws {
        try database.write { db in
            guard var term = try DictionaryTerm.fetchOne(db,
                sql: "SELECT * FROM dictionaryTerms WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString]) else { return }
            term.updatedAt = Self.nextTermDate(after: term.updatedAt)
            term.deletedAt = term.updatedAt
            term.deviceID = deviceID
            term.text = ""
            term.aliases = []
            try term.update(db)
        }
    }

    public func listTerms() throws -> [DictionaryTerm] {
        try database.read { db in
            try DictionaryTerm.fetchAll(db,
                sql: "SELECT * FROM dictionaryTerms WHERE deletedAt IS NULL ORDER BY id")
        }
    }

    public func dictionaryTerm(id: UUID) throws -> DictionaryTerm? {
        try database.read { db in
            try DictionaryTerm.fetchOne(db, key: id.uuidString)
        }
    }

    private static func normalizedAliases(_ aliases: [String]) -> [String] {
        aliases.compactMap { alias in
            let trimmed = DictionaryTerm.trimEdgeWhitespace(alias)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func nextTermDate(after previous: Date) -> Date {
        // Keep rapid edits ordered even if the wall clock moves backwards.
        Date(timeIntervalSince1970: max(Date.now.timeIntervalSince1970, previous.timeIntervalSince1970 + 0.000001))
    }

    private static func validateTerm(text: String, aliases: [String], excluding id: UUID?, in db: Database) throws {
        guard !DictionaryTerm.matchKey(text).isEmpty else { throw DictionaryError.emptyText }
        let existing = try DictionaryTerm.fetchAll(db,
            sql: "SELECT * FROM dictionaryTerms WHERE deletedAt IS NULL ORDER BY id")
        var owners: [String: UUID] = [:]
        for term in existing where term.id != id {
            for value in [term.text] + term.aliases {
                let key = DictionaryTerm.matchKey(value)
                if !key.isEmpty { owners[key] = owners[key] ?? term.id }
            }
        }
        for value in [text] + aliases {
            if let owner = owners[DictionaryTerm.matchKey(value)] {
                throw DictionaryError.conflict(value: value, termID: owner)
            }
        }
    }

    public func audioURL(for record: MemoryRecord) -> URL? {
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
            let uuidChecks = ["id", "deviceID"].map { column in
                """
                CHECK (typeof(\(column)) = 'text' AND length(CAST(\(column) AS BLOB)) = 36
                    AND length(replace(\(column), '-', '')) = 32
                    AND substr(\(column), 9, 1) = '-' AND substr(\(column), 14, 1) = '-'
                    AND substr(\(column), 19, 1) = '-' AND substr(\(column), 24, 1) = '-'
                    AND \(column) NOT GLOB '*[^0-9A-F-]*')
                """
            }.joined(separator: ",\n")
            try db.execute(sql: """
                CREATE TABLE storeMetadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    deviceID TEXT NOT NULL
                );
                CREATE TABLE records (
                    id TEXT PRIMARY KEY NOT NULL,
                    deviceID TEXT NOT NULL,
                    kind TEXT CHECK (kind IS NULL OR typeof(kind) = 'text'),
                    createdAt REAL,
                    rawText TEXT,
                    finalText TEXT,
                    appBundleID TEXT,
                    appName TEXT,
                    project TEXT,
                    modelID TEXT,
                    durationSeconds REAL,
                    audioPath TEXT,
                    deletedAt REAL CHECK (deletedAt IS NULL OR typeof(deletedAt) IN ('real', 'integer')),
                    \(uuidChecks),
                    CHECK (
                        (deletedAt IS NULL AND kind IS NOT NULL AND createdAt IS NOT NULL
                            AND rawText IS NOT NULL AND finalText IS NOT NULL)
                        OR (deletedAt IS NOT NULL AND kind IS NULL AND createdAt IS NULL
                            AND rawText IS NULL AND finalText IS NULL AND appBundleID IS NULL
                            AND appName IS NULL AND project IS NULL AND modelID IS NULL
                            AND durationSeconds IS NULL AND audioPath IS NULL)
                    )
                );
                CREATE TRIGGER records_positive_rowid AFTER INSERT ON records WHEN NEW.rowid < 1
                BEGIN SELECT RAISE(ABORT, 'record rowids must be positive'); END;
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
        migrator.registerMigration("dictionary.createTerms") { db in
            try db.execute(sql: """
                CREATE TABLE dictionaryTerms (
                    id TEXT PRIMARY KEY NOT NULL,
                    text TEXT NOT NULL,
                    aliases TEXT NOT NULL,
                    updatedAt REAL NOT NULL,
                    deviceID TEXT NOT NULL,
                    deletedAt REAL,
                    CHECK (typeof(updatedAt) IN ('real', 'integer')),
                    CHECK (deletedAt IS NULL OR typeof(deletedAt) IN ('real', 'integer')),
                    CHECK (deletedAt IS NULL OR (text = '' AND aliases = '[]'))
                );
                """)
        }
        return migrator
    }
}
