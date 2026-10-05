//
//  SQLiteIndexStore.swift
//  DownloadKit
//
//  The production index store, on the system SQLite library. This file is the only place in
//  the package that imports SQLite3.
//

import Foundation
import SQLite3

/// The durable index: one SQLite database in the storage root, opened with the system SQLite
/// library (no third-party dependency).
///
/// Contract, beyond ``DownloadIndexStore``:
/// - Schema version 1 lives in its own table. Opening a database whose stored version is newer
///   than ``IndexSchema/currentVersion`` throws ``DownloadError/unsupportedSchema(found:supported:)``
///   before anything is written; a file that is not a database, a database without the version
///   table, or a record that does not decode throws ``DownloadError/corruptIndex``. Neither case
///   modifies, resets or recreates the file.
/// - Every change set is one `BEGIN IMMEDIATE` transaction: all of it or none of it. The
///   database runs in WAL mode with full synchronous commits, so a committed change survives
///   process exit and a torn write is rolled back on the next open.
/// - Records are stored as their `Codable` encoding, which carries every field the port defines
///   (journal, finalisation destination, stop binding, validators, relative paths); paths are
///   relative to the storage root and re-validated when decoded. Cleanup intent has its own table.
/// - Progress-only change sets (an active record whose byte counts or timestamp changed and
///   nothing else) are coalesced: at most one such write per `progressWriteInterval`; any other
///   change set writes immediately and carries the coalesced progress with it. Coalesced
///   progress that was not yet written is lost if the process ends, which only loses advisory
///   byte counts.
/// - One connection, confined to this actor. Callers apply change sets one at a time, as the
///   manager does. ``close()`` writes coalesced progress and closes the connection.
///
/// The index file is kept in backups (only `media/` and `staging/` are excluded), so a restored
/// device shows records whose files are gone as ``DownloadState/missing``.
public actor SQLiteIndexStore: DownloadIndexStore {
    /// The database file name inside the storage root.
    public static let fileName = "index.sqlite"

    private var connection: Connection?
    /// What the database holds, as last committed.
    private var committed: IndexContents?
    private var pendingProgress: [DownloadID: IndexRecord] = [:]
    private var lastWrite: Date?
    private let progressWriteInterval: TimeInterval
    private let clock: any DownloadClock
    /// Statements left before an injected failure (tests only).
    private var statementsBeforeFailure: Int?
    private(set) var writeCount = 0

    /// Opens (or creates) the database at `fileURL`.
    ///
    /// Throws ``DownloadError/storageUnavailable`` when the file cannot be opened,
    /// ``DownloadError/unsupportedSchema(found:supported:)`` for a newer schema and
    /// ``DownloadError/corruptIndex`` for anything that is not a version 1 index.
    public init(fileURL: URL, progressWriteInterval: TimeInterval = 1, clock: any DownloadClock = SystemClock()) throws {
        self.progressWriteInterval = max(0, progressWriteInterval)
        self.clock = clock
        // Released, and so closed, if anything below throws.
        let connection = Connection(try Self.openDatabase(at: fileURL))
        try Self.prepareSchema(connection.handle)
        self.committed = try Self.readContents(connection.handle)
        self.connection = connection
    }

    /// A ``DownloadDependencies/makeIndexStore`` closure that opens ``fileName`` in the storage
    /// root.
    public static func opener(progressWriteInterval: TimeInterval = 1, clock: any DownloadClock = SystemClock()) -> @Sendable (URL) async throws -> any DownloadIndexStore {
        { root in
            try SQLiteIndexStore(fileURL: root.appendingPathComponent(fileName, isDirectory: false), progressWriteInterval: progressWriteInterval, clock: clock)
        }
    }

    // MARK: DownloadIndexStore

    public func load() throws -> IndexContents? {
        guard connection != nil else { throw DownloadError.storageUnavailable }
        guard !pendingProgress.isEmpty else { return committed }
        return IndexChangeSet(upserts: pendingProgress.values.sorted { $0.id < $1.id }, nextGeneration: committed?.nextGeneration ?? 1).applied(to: committed)
    }

    public func apply(_ changes: IndexChangeSet) async throws {
        guard connection != nil else { throw DownloadError.persistenceFailed }
        let now = await clock.now()
        guard let database = connection?.handle else { throw DownloadError.persistenceFailed }
        if isProgressOnly(changes) {
            for record in changes.upserts { pendingProgress[record.id] = record }
            if let lastWrite, now < lastWrite.addingTimeInterval(progressWriteInterval) { return }
        }
        var upserts = pendingProgress
        for id in changes.deletions { upserts[id] = nil }
        for record in changes.upserts { upserts[record.id] = record }
        let effective = IndexChangeSet(
            upserts: upserts.values.sorted { $0.id < $1.id },
            deletions: changes.deletions,
            nextGeneration: max(changes.nextGeneration, committed?.nextGeneration ?? 1),
            defaultPolicy: changes.defaultPolicy,
            cleanupQueued: changes.cleanupQueued,
            cleanupCompleted: changes.cleanupCompleted
        )
        try write(effective, to: database)
        committed = effective.applied(to: committed)
        pendingProgress = [:]
        lastWrite = now
        writeCount += 1
    }

    /// Writes coalesced progress now.
    public func flush() throws {
        guard let database = connection?.handle, !pendingProgress.isEmpty else { return }
        let effective = IndexChangeSet(upserts: pendingProgress.values.sorted { $0.id < $1.id }, nextGeneration: committed?.nextGeneration ?? 1)
        try write(effective, to: database)
        committed = effective.applied(to: committed)
        pendingProgress = [:]
        writeCount += 1
    }

    /// Writes coalesced progress (best effort) and closes the connection. Later calls fail.
    public func close() {
        try? flush()
        connection = nil
    }

    // MARK: Test hooks

    /// Makes the next write fail after `statements` statements of its transaction ran.
    func injectFailure(afterStatements statements: Int) {
        statementsBeforeFailure = statements
    }

    var pendingProgressCount: Int { pendingProgress.count }

    // MARK: Coalescing

    /// Only byte counts and the timestamp of active records changed.
    private func isProgressOnly(_ changes: IndexChangeSet) -> Bool {
        guard let committed, !changes.upserts.isEmpty, changes.deletions.isEmpty, changes.defaultPolicy == nil,
              changes.cleanupQueued.isEmpty, changes.cleanupCompleted.isEmpty,
              changes.nextGeneration <= committed.nextGeneration else { return false }
        return changes.upserts.allSatisfy { record in
            guard record.phase == .active, let stored = committed.records.first(where: { $0.id == record.id }) else { return false }
            var neutral = record
            neutral.bytesWritten = stored.bytesWritten
            neutral.expectedBytes = stored.expectedBytes
            neutral.updatedAt = stored.updatedAt
            return neutral == stored
        }
    }

    // MARK: Writing

    private func write(_ changes: IndexChangeSet, to database: OpaquePointer) throws {
        do {
            try Self.execute(database, "BEGIN IMMEDIATE")
            for record in changes.upserts {
                try countStatement()
                let statement = try Statement(database, "INSERT OR REPLACE INTO dk_records (id, generation, journal, record) VALUES (?, ?, ?, ?)")
                statement.bind(1, record.id.rawValue)
                statement.bind(2, Int64(bitPattern: record.generation))
                statement.bind(3, record.journal.rawValue)
                statement.bind(4, try Self.encoder.encode(record))
                try statement.run()
            }
            for id in changes.deletions {
                try countStatement()
                let statement = try Statement(database, "DELETE FROM dk_records WHERE id = ?")
                statement.bind(1, id.rawValue)
                try statement.run()
            }
            for path in changes.cleanupQueued {
                try countStatement()
                let statement = try Statement(database, "INSERT OR IGNORE INTO dk_cleanup (path) VALUES (?)")
                statement.bind(1, path.rawValue)
                try statement.run()
            }
            for path in changes.cleanupCompleted {
                try countStatement()
                let statement = try Statement(database, "DELETE FROM dk_cleanup WHERE path = ?")
                statement.bind(1, path.rawValue)
                try statement.run()
            }
            try countStatement()
            let generation = try Statement(database, "INSERT OR REPLACE INTO dk_globals (key, value) VALUES ('next_generation', ?)")
            generation.bind(1, Int64(bitPattern: changes.nextGeneration))
            try generation.run()
            if let policy = changes.defaultPolicy {
                try countStatement()
                let statement = try Statement(database, "INSERT OR REPLACE INTO dk_globals (key, value) VALUES ('default_policy', ?)")
                statement.bind(1, try Self.encoder.encode(policy))
                try statement.run()
            }
            try Self.execute(database, "COMMIT")
        } catch {
            try? Self.execute(database, "ROLLBACK")
            throw DownloadError.persistenceFailed
        }
    }

    private func countStatement() throws {
        guard let remaining = statementsBeforeFailure else { return }
        if remaining <= 0 {
            statementsBeforeFailure = nil
            throw SQLiteFailure(code: SQLITE_IOERR)
        }
        statementsBeforeFailure = remaining - 1
    }

    // MARK: Opening

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw DownloadError.storageUnavailable
        }
        sqlite3_busy_timeout(handle, 2_000)
        return handle
    }

    /// Creates schema version 1 in an empty database, refuses anything else that is not a
    /// version 1 index, then switches to WAL. Nothing is written before the version check.
    private static func prepareSchema(_ database: OpaquePointer) throws {
        let tables: [String]
        do {
            tables = try strings(database, "SELECT name FROM sqlite_master WHERE type = 'table'")
        } catch let failure as SQLiteFailure {
            throw failure.loadError
        }
        if tables.isEmpty {
            do {
                try execute(database, "PRAGMA journal_mode = WAL")
                try execute(database, "BEGIN IMMEDIATE")
                try execute(database, "CREATE TABLE dk_schema (version INTEGER NOT NULL)")
                try execute(database, "INSERT INTO dk_schema (version) VALUES (\(IndexSchema.currentVersion))")
                try execute(database, "CREATE TABLE dk_globals (key TEXT PRIMARY KEY NOT NULL, value BLOB) WITHOUT ROWID")
                try execute(database, "CREATE TABLE dk_records (id TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL, journal TEXT NOT NULL, record BLOB NOT NULL) WITHOUT ROWID")
                try execute(database, "CREATE TABLE dk_cleanup (path TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID")
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw DownloadError.storageUnavailable
            }
        } else {
            guard tables.contains("dk_schema") else { throw DownloadError.corruptIndex }
            let versions: [Int64]
            do {
                versions = try integers(database, "SELECT version FROM dk_schema")
            } catch let failure as SQLiteFailure {
                throw failure.loadError
            }
            guard let version = versions.max().map(Int.init) else { throw DownloadError.corruptIndex }
            guard version <= IndexSchema.currentVersion else {
                throw DownloadError.unsupportedSchema(found: version, supported: IndexSchema.currentVersion)
            }
            guard version >= 1, tables.contains("dk_globals"), tables.contains("dk_records"), tables.contains("dk_cleanup") else {
                throw DownloadError.corruptIndex
            }
            do {
                try execute(database, "PRAGMA journal_mode = WAL")
            } catch let failure as SQLiteFailure {
                throw failure.loadError
            }
        }
        do {
            try execute(database, "PRAGMA synchronous = FULL")
        } catch let failure as SQLiteFailure {
            throw failure.loadError
        }
    }

    private static func readContents(_ database: OpaquePointer) throws -> IndexContents? {
        do {
            var nextGeneration: UInt64?
            var defaultPolicy: NetworkPolicy?
            let globals = try Statement(database, "SELECT key, value FROM dk_globals")
            while try globals.next() {
                switch globals.text(0) {
                case "next_generation":
                    nextGeneration = UInt64(bitPattern: globals.int64(1))
                case "default_policy":
                    guard let data = globals.data(1) else { throw DownloadError.corruptIndex }
                    defaultPolicy = try decoder.decode(NetworkPolicy.self, from: data)
                default:
                    // Unknown keys are kept as they are.
                    break
                }
            }
            guard let nextGeneration else { return nil }

            var records: [IndexRecord] = []
            let rows = try Statement(database, "SELECT id, record FROM dk_records ORDER BY id")
            while try rows.next() {
                guard let id = rows.text(0), let data = rows.data(1) else { throw DownloadError.corruptIndex }
                let record = try decoder.decode(IndexRecord.self, from: data)
                guard record.id.rawValue == id else { throw DownloadError.corruptIndex }
                records.append(record)
            }

            var cleanup: [RelativePath] = []
            let paths = try Statement(database, "SELECT path FROM dk_cleanup ORDER BY path")
            while try paths.next() {
                guard let raw = paths.text(0) else { throw DownloadError.corruptIndex }
                cleanup.append(try RelativePath(raw))
            }
            return IndexContents(schemaVersion: IndexSchema.currentVersion, nextGeneration: nextGeneration, defaultPolicy: defaultPolicy, records: records, cleanupPaths: cleanup)
        } catch let failure as SQLiteFailure {
            throw failure.loadError
        } catch let error as DownloadError {
            if case .unsupportedSchema = error { throw error }
            throw DownloadError.corruptIndex
        } catch {
            throw DownloadError.corruptIndex
        }
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw SQLiteFailure(code: code) }
    }

    private static func strings(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        let statement = try Statement(database, sql)
        var result: [String] = []
        while try statement.next() {
            if let value = statement.text(0) { result.append(value) }
        }
        return result
    }

    private static func integers(_ database: OpaquePointer, _ sql: String) throws -> [Int64] {
        let statement = try Statement(database, sql)
        var result: [Int64] = []
        while try statement.next() { result.append(statement.int64(0)) }
        return result
    }
}

/// A failed SQLite call and its result code.
private struct SQLiteFailure: Error {
    let code: Int32

    /// The typed error for a failure while opening or reading.
    var loadError: DownloadError {
        switch code & 0xFF {
        case SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_FORMAT: return .corruptIndex
        default: return .storageUnavailable
        }
    }
}

/// The open database handle, closed when released. Confined to the store's actor.
private final class Connection {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

/// One prepared statement, finalized when released. Confined to the store's actor.
private final class Statement {
    private let handle: OpaquePointer

    init(_ database: OpaquePointer, _ sql: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else { throw SQLiteFailure(code: code) }
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func bind(_ index: Int32, _ text: String) {
        sqlite3_bind_text(handle, index, text, -1, Self.transient)
    }

    func bind(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(handle, index, value)
    }

    func bind(_ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
        }
    }

    /// Runs a statement that returns no rows.
    func run() throws {
        let code = sqlite3_step(handle)
        guard code == SQLITE_DONE else { throw SQLiteFailure(code: code) }
    }

    /// Advances to the next row; false when there are no more.
    func next() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteFailure(code: code)
        }
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func data(_ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard let pointer = sqlite3_column_blob(handle, column) else { return count == 0 ? Data() : nil }
        return Data(bytes: pointer, count: count)
    }
}
