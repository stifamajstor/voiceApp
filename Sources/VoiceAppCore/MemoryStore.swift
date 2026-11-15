import Foundation
import GRDB

public final class MemoryStore: Sendable {
    public enum StoreError: Error {
        case invalidAudioPath
        case missingDeviceID
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
        database = try DatabaseQueue(path: self.directory.appending(path: "store.sqlite").path)
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
        kind: RecordKind = .dictation,
        createdAt: Date = .now,
        rawText: String,
        finalText: String? = nil,
        appBundleID: String? = nil,
        appName: String? = nil,
        project: String? = nil,
        modelID: String? = nil,
        durationSeconds: Double? = nil,
        audioPath: String? = nil
    ) throws -> MemoryRecord {
        // Match the timestamp precision restored from SQLite's Unix-epoch REAL.
        let record = MemoryRecord(
            id: UUID(), deviceID: deviceID, kind: kind,
            createdAt: Date(timeIntervalSince1970: createdAt.timeIntervalSince1970),
            rawText: rawText, finalText: finalText ?? rawText, appBundleID: appBundleID,
            appName: appName, project: project, modelID: modelID,
            durationSeconds: durationSeconds, audioPath: audioPath, deletedAt: nil
        )
        return try database.write { db in
            if let audioPath { _ = try audioURL(for: audioPath) }
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
                ORDER BY createdAt DESC, id DESC LIMIT ?
                """, arguments: [kind?.rawValue, kind?.rawValue, limit])
        }
    }

    public func search(_ query: String, kind: RecordKind? = nil, limit: Int = 50) throws -> [MemoryRecord] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            let tokens = try db.makeTokenizer(.unicode61()).tokenize(query: query)
            guard !tokens.isEmpty else { return [] }
            // Quoting tokens prevents typed text from becoming FTS operators or column selectors.
            let pattern = tokens.map { "\"" + $0.token.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND ")
            return try MemoryRecord.fetchAll(db, sql: """
                SELECT records.* FROM records
                JOIN recordsFTS ON recordsFTS.rowid = records.rowid
                WHERE recordsFTS MATCH ? AND deletedAt IS NULL AND (? IS NULL OR kind = ?)
                ORDER BY createdAt DESC, id DESC LIMIT ?
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
            if let path = record.audioPath {
                let url = try audioURL(for: path)
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // A missing file must not prevent retrying an interrupted deletion.
                }
            }
            try db.execute(sql: """
                UPDATE records SET kind = NULL, createdAt = NULL, rawText = NULL, finalText = NULL,
                    appBundleID = NULL, appName = NULL, project = NULL, modelID = NULL,
                    durationSeconds = NULL, audioPath = NULL, deletedAt = ?
                WHERE id = ?
                """, arguments: [Date.now.timeIntervalSince1970, id.uuidString])
        }
    }

    private func audioURL(for path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !path.utf8.contains(0),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !components[0].lowercased().hasPrefix("store.sqlite") else { throw StoreError.invalidAudioPath }
        var url = directory
        for (index, component) in components.enumerated() {
            url.append(path: String(component))
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let expectedType: FileAttributeType = index == components.count - 1 ? .typeRegular : .typeDirectory
                guard attributes[.type] as? FileAttributeType == expectedType else {
                    throw StoreError.invalidAudioPath
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
        }
        return url
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
                    id TEXT PRIMARY KEY NOT NULL,
                    deviceID TEXT NOT NULL,
                    kind TEXT CHECK (kind IN ('dictation', 'note', 'prompt')),
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
                CREATE INDEX records_recent ON records (createdAt DESC, id DESC) WHERE deletedAt IS NULL;
                CREATE UNIQUE INDEX records_audio ON records (audioPath) WHERE audioPath IS NOT NULL;
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
