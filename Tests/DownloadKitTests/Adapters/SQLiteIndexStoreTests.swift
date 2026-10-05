//
//  SQLiteIndexStoreTests.swift
//  DownloadKitTests
//

import Foundation
import SQLite3
import XCTest
@testable import DownloadKit

final class SQLiteIndexStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("sqlite")
    }

    override func tearDown() {
        directory.remove()
    }

    private var fileURL: URL { directory.appending(SQLiteIndexStore.fileName) }

    private func open(_ url: URL? = nil, clock: any DownloadClock = SystemClock(), interval: TimeInterval = 1) throws -> SQLiteIndexStore {
        try SQLiteIndexStore(fileURL: url ?? fileURL, progressWriteInterval: interval, clock: clock)
    }

    private func record(
        _ raw: String,
        phase: RecordPhase,
        generation: UInt64 = 3,
        journal: FinalizationJournal = .notStarted,
        binding: TaskBinding? = nil,
        stopping: TaskBinding? = nil,
        staging: RelativePath? = nil,
        destination: RelativePath? = nil,
        finalPath: RelativePath? = nil,
        resume: RelativePath? = nil,
        bytes: Int64 = 0,
        validators: ResponseValidators? = nil,
        integrity: IntegrityRecord? = nil,
        policy: NetworkPolicy? = nil,
        updatedAt: Date = referenceDate
    ) -> IndexRecord {
        IndexRecord(
            unchecked: itemID(raw),
            request: RequestIdentity(sourceURL: URL(string: "https://media.example.com/\(raw).m4a?sig=abc")!, revision: ContentRevision("r1"), expectedLength: 100, checksum: ContentChecksum(hexDigest: "AB12")),
            metadata: DownloadMetadata(title: "Title \(raw)"),
            policy: policy,
            phase: phase,
            generation: generation,
            automaticRetryCount: 1,
            retryAt: nil,
            binding: binding,
            stoppingBinding: stopping,
            bytesWritten: bytes,
            expectedBytes: 100,
            validators: validators,
            integrity: integrity,
            journal: journal,
            stagingPath: staging,
            finalizationDestination: destination,
            finalPath: finalPath,
            resumeDataPath: resume,
            createdAt: referenceDate,
            updatedAt: updatedAt
        )
    }

    private func everyShape() -> [IndexRecord] {
        let binding = TaskBinding(sessionIdentifier: "session.one", taskIdentifier: 12, generation: 3)
        return [
            record("queued", phase: .queued),
            record("active", phase: .active, binding: binding, bytes: 40),
            record("paused", phase: .paused, stopping: binding, resume: path("staging/resume-1"), validators: ResponseValidators(entityTag: "\"v1\"", lastModified: "Mon, 05 Oct 2026 10:00:00 GMT")),
            record("waiting", phase: .waiting(.retryScheduled(at: referenceDate.addingTimeInterval(30.5)))),
            record("policy", phase: .waiting(.networkPolicy), policy: .anyNetwork),
            record("captured", phase: .active, journal: .captured, staging: path("staging/abc"), destination: path("media/item-3.m4a"), bytes: 100),
            record("completed", phase: .completed(at: referenceDate.addingTimeInterval(0.25)), journal: .committed, finalPath: path("media/item-2"), bytes: 100, integrity: IntegrityRecord(verifiedLength: 100, checksum: ContentChecksum(hexDigest: "ab12"))),
            record("failed", phase: .failed(DownloadFailure(kind: .http, httpStatus: 404))),
            record("rejected", phase: .failed(DownloadFailure(kind: .integrity)), journal: .rejected),
            record("removing", phase: .removing, generation: 9, stopping: binding, destination: path("media/item-3")),
            record("missing", phase: .missing),
        ]
    }

    func testFreshStoreLoadsNothing() async throws {
        let store = try open()
        let contents = try await store.load()
        XCTAssertNil(contents)
    }

    func testEveryRecordShapeRoundTripsAcrossReopen() async throws {
        let records = everyShape()
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: records, nextGeneration: 10, defaultPolicy: .anyNetwork, cleanupQueued: [path("staging/old"), path("media/item-1")]))
        await store.close()

        let reopened = try open()
        let contents = try await reopened.load()
        XCTAssertEqual(contents?.records, records.sorted { $0.id < $1.id })
        XCTAssertEqual(contents?.nextGeneration, 10)
        XCTAssertEqual(contents?.defaultPolicy, .anyNetwork)
        XCTAssertEqual(contents?.cleanupPaths, [path("media/item-1"), path("staging/old")])
        XCTAssertEqual(contents?.schemaVersion, IndexSchema.currentVersion)
    }

    func testDeletionsCleanupCompletionAndGenerationNeverDecreases() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10, cleanupQueued: [path("staging/old")]))
        try await store.apply(IndexChangeSet(deletions: [itemID("missing"), itemID("queued")], nextGeneration: 4, cleanupCompleted: [path("staging/old")]))
        await store.close()

        let contents = try await open().load()
        XCTAssertEqual(contents?.records.map(\.id.rawValue).contains("missing"), false)
        XCTAssertEqual(contents?.records.map(\.id.rawValue).contains("queued"), false)
        XCTAssertEqual(contents?.cleanupPaths, [])
        XCTAssertEqual(contents?.nextGeneration, 10, "a lower generation never rewinds the counter")
    }

    func testStoredRowsHoldRelativePathsAndNoRootPath() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10))
        await store.close()

        let raw = try rawStrings("SELECT CAST(record AS TEXT) FROM dk_records").joined()
        XCTAssertTrue(raw.contains("\"staging\\/abc\"") || raw.contains("\"staging/abc\""))
        XCTAssertFalse(raw.contains(directory.url.path), "no absolute path is stored")
    }

    func testNewerSchemaIsRefusedAndLeftUntouched() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10))
        await store.close()
        let newer = IndexSchema.currentVersion + 1
        try rawExecute("UPDATE dk_schema SET version = \(newer)")
        let before = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .unsupportedSchema(found: newer, supported: IndexSchema.currentVersion))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(try rawStrings("SELECT CAST(version AS TEXT) FROM dk_schema"), ["\(newer)"], "the version is not reset")
    }

    func testUnreadableFileIsCorruptAndPreserved() throws {
        let garbage = Data(repeating: 0x5A, count: 8_192)
        try garbage.write(to: fileURL)

        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .corruptIndex)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
    }

    func testForeignDatabaseIsRefused() throws {
        try rawExecute("CREATE TABLE other (x INTEGER)")
        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .corruptIndex)
        }
        XCTAssertEqual(try rawStrings("SELECT name FROM sqlite_master WHERE type = 'table'"), ["other"], "nothing was created in it")
    }

    func testUndecodableRecordIsCorruptAndPreserved() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10))
        await store.close()
        try rawExecute("UPDATE dk_records SET record = CAST('{\"id\":\"failed\",\"stagingPath\":\"../escape\"}' AS BLOB) WHERE id = 'failed'")

        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .corruptIndex)
        }
        XCTAssertEqual(try rawStrings("SELECT id FROM dk_records").count, everyShape().count, "no row was dropped")
    }

    func testFailedTransactionLeavesNothingBehind() async throws {
        let store = try open()
        let initial = everyShape()
        try await store.apply(IndexChangeSet(upserts: initial, nextGeneration: 10))
        let before = try await store.load()

        await store.injectFailure(afterStatements: 3)
        let changes = IndexChangeSet(
            upserts: [record("new-a", phase: .queued), record("new-b", phase: .queued), record("new-c", phase: .queued)],
            deletions: [itemID("completed")],
            nextGeneration: 20,
            defaultPolicy: .anyNetwork,
            cleanupQueued: [path("staging/x")]
        )
        do {
            try await store.apply(changes)
            XCTFail("the injected failure did not surface")
        } catch {
            XCTAssertEqual(error as? DownloadError, .persistenceFailed)
        }
        let afterFailure = try await store.load()
        XCTAssertEqual(afterFailure, before)
        await store.close()
        let reopened = try open()
        let persisted = try await reopened.load()
        XCTAssertEqual(persisted, before, "the partial transaction was rolled back on disk")

        try await reopened.apply(changes)
        let applied = try await reopened.load()
        XCTAssertEqual(applied?.records.count, initial.count + 2)
    }

    func testProgressWritesAreCoalescedAndCarriedByTheNextStateChange() async throws {
        let clock = ManualClock()
        let store = try open(clock: clock, interval: 1)
        let active = record("active", phase: .active, bytes: 0)
        let other = record("queued", phase: .queued)
        try await store.apply(IndexChangeSet(upserts: [active, other], nextGeneration: 10))
        let writesAfterSetup = await store.writeCount

        for bytes in [10, 20, 30, 40] as [Int64] {
            var progressed = active
            progressed.bytesWritten = bytes
            progressed.updatedAt = referenceDate.addingTimeInterval(Double(bytes))
            try await store.apply(IndexChangeSet(upserts: [progressed], nextGeneration: 10))
        }
        let writesWithinInterval = await store.writeCount
        XCTAssertEqual(writesWithinInterval, writesAfterSetup, "progress within the interval is not written")
        let latest = try await store.load()
        XCTAssertEqual(latest?.records.first { $0.id == itemID("active") }?.bytesWritten, 40)

        // A state change writes at once and carries the coalesced progress.
        var paused = other
        paused.phase = .paused
        try await store.apply(IndexChangeSet(upserts: [paused], nextGeneration: 10))
        let pending = await store.pendingProgressCount
        XCTAssertEqual(pending, 0)
        await store.close()
        var contents = try await open().load()
        XCTAssertEqual(contents?.records.first { $0.id == itemID("active") }?.bytesWritten, 40)
        XCTAssertEqual(contents?.records.first { $0.id == itemID("queued") }?.phase, .paused)

        // After the interval a progress write goes through on its own.
        let store2 = try open(clock: clock, interval: 1)
        var progressed = active
        progressed.bytesWritten = 50
        try await store2.apply(IndexChangeSet(upserts: [progressed], nextGeneration: 10))
        await clock.advance(by: 1)
        progressed.bytesWritten = 60
        try await store2.apply(IndexChangeSet(upserts: [progressed], nextGeneration: 10))
        let writes = await store2.writeCount
        XCTAssertEqual(writes, 2, "the first write of a connection and one per interval")
        contents = try await store2.load()
        XCTAssertEqual(contents?.records.first { $0.id == itemID("active") }?.bytesWritten, 60)
    }

    func testPhaseOrBindingChangesAreNeverCoalesced() async throws {
        let clock = ManualClock()
        let store = try open(clock: clock, interval: 60)
        let queued = record("item", phase: .queued)
        try await store.apply(IndexChangeSet(upserts: [queued], nextGeneration: 10))
        try await store.apply(IndexChangeSet(upserts: [record("item", phase: .active, bytes: 1)], nextGeneration: 10))
        try await store.apply(IndexChangeSet(upserts: [record("item", phase: .active, binding: TaskBinding(sessionIdentifier: "s", taskIdentifier: 1, generation: 3), bytes: 2)], nextGeneration: 10))
        let writes = await store.writeCount
        XCTAssertEqual(writes, 3)
    }

    func testCommittedStateSurvivesACrashAndATornWriteIsDiscarded() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: [record("a", phase: .queued)], nextGeneration: 4))
        let afterFirst = try await store.load()
        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        let firstSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int)
        try await store.apply(IndexChangeSet(upserts: [record("b", phase: .queued), record("c", phase: .paused)], nextGeneration: 5))
        let afterSecond = try await store.load()

        // Power loss with the connection still open: copy the files as they are.
        let crashed = try TemporaryDirectory("sqlite-crash")
        defer { crashed.remove() }
        let copy = crashed.appending(SQLiteIndexStore.fileName)
        try FileManager.default.copyItem(at: fileURL, to: copy)
        try FileManager.default.copyItem(at: walURL, to: URL(fileURLWithPath: copy.path + "-wal"))
        let recovered = try await open(copy).load()
        XCTAssertEqual(recovered, afterSecond)

        // A write torn inside the second transaction: its frames have no commit and are ignored.
        let torn = try TemporaryDirectory("sqlite-torn")
        defer { torn.remove() }
        let tornCopy = torn.appending(SQLiteIndexStore.fileName)
        try FileManager.default.copyItem(at: fileURL, to: tornCopy)
        let wal = try Data(contentsOf: walURL)
        XCTAssertGreaterThan(wal.count, firstSize)
        try wal.prefix(firstSize + (wal.count - firstSize) / 2).write(to: URL(fileURLWithPath: tornCopy.path + "-wal"))
        let rolledBack = try await open(tornCopy).load()
        XCTAssertEqual(rolledBack, afterFirst)
        await store.close()
    }

    func testClosedStoreRefusesWork() async throws {
        let store = try open()
        await store.close()
        do {
            try await store.apply(IndexChangeSet(nextGeneration: 2))
            XCTFail("a closed store accepted a write")
        } catch {
            XCTAssertEqual(error as? DownloadError, .persistenceFailed)
        }
    }

    func testOpenerCreatesTheIndexInsideTheRoot() async throws {
        let store = try await SQLiteIndexStore.opener()(directory.url)
        try await store.apply(IndexChangeSet(nextGeneration: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: Invalid indexes and migration

    /// The bytes of the database and of its companion files, to prove a refusal wrote nothing.
    private func snapshotFiles() -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in ["", "-wal", "-journal"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: fileURL.path + suffix)) { files[suffix] = data }
        }
        return files
    }

    private func assertRefusedUnchanged(_ expected: DownloadError = .corruptIndex, file: StaticString = #filePath, line: UInt = #line) {
        let before = snapshotFiles()
        XCTAssertThrowsError(try open(), file: file, line: line) { error in
            XCTAssertEqual(error as? DownloadError, expected, file: file, line: line)
        }
        XCTAssertEqual(snapshotFiles(), before, "a refused index is not modified", file: file, line: line)
    }

    func testPopulatedIndexWithoutItsCounterIsRefusedNotFresh() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10, cleanupQueued: [path("staging/old")]))
        await store.close()
        try rawExecute("DELETE FROM dk_globals WHERE key = 'next_generation'")

        assertRefusedUnchanged()
        XCTAssertEqual(try rawStrings("SELECT id FROM dk_records").count, everyShape().count, "the records are kept")
    }

    func testContradictoryOrInconsistentRecordsAreRefused() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10))
        await store.close()
        let original = try rawStrings("SELECT CAST(record AS TEXT) FROM dk_records WHERE id = 'completed'")[0]

        // Decodes, but a completed record without a final path contradicts itself.
        let contradictory = original.replacingOccurrences(of: "\"finalPath\":\"media\\/item-2\",", with: "").replacingOccurrences(of: "\"finalPath\":\"media/item-2\",", with: "")
        XCTAssertNotEqual(contradictory, original)
        try rawExecute("UPDATE dk_records SET record = CAST('\(contradictory)' AS BLOB) WHERE id = 'completed'")
        assertRefusedUnchanged()

        // A record whose generation is not below the stored counter.
        try rawExecute("UPDATE dk_records SET record = CAST('\(original)' AS BLOB) WHERE id = 'completed'")
        try rawExecute("UPDATE dk_globals SET value = 3 WHERE key = 'next_generation'")
        assertRefusedUnchanged()

        // A row whose columns disagree with its record.
        try rawExecute("UPDATE dk_globals SET value = 10 WHERE key = 'next_generation'")
        try rawExecute("UPDATE dk_records SET generation = 7 WHERE id = 'completed'")
        assertRefusedUnchanged()
    }

    func testCorruptIndexInRollbackJournalModeIsRefusedWithoutAnyWrite() throws {
        // A version 1 index written by another configuration in rollback-journal mode.
        try rawExecute("""
            PRAGMA journal_mode = DELETE;
            CREATE TABLE dk_schema (version INTEGER NOT NULL);
            INSERT INTO dk_schema (version) VALUES (1);
            CREATE TABLE dk_globals (key TEXT PRIMARY KEY NOT NULL, value BLOB) WITHOUT ROWID;
            CREATE TABLE dk_records (id TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL, journal TEXT NOT NULL, record BLOB NOT NULL) WITHOUT ROWID;
            CREATE TABLE dk_cleanup (path TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;
            INSERT INTO dk_globals (key, value) VALUES ('next_generation', 5);
            INSERT INTO dk_records (id, generation, journal, record) VALUES ('a', 1, 'notStarted', CAST('{"id":"a"}' AS BLOB));
            """)
        let header = try Data(contentsOf: fileURL)
        XCTAssertEqual(header[18], 1, "rollback-journal mode before")

        assertRefusedUnchanged()
        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(after[18], 1, "the journal mode was not switched to WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-wal"))
    }

    func testVersionOneIndexIsMigratedAndKeepsItsRecords() async throws {
        // Written by a version 1 build: no unresolved-attempt fields, version 1.
        let store = try open()
        let records = everyShape()
        try await store.apply(IndexChangeSet(upserts: records, nextGeneration: 10))
        await store.close()
        for record in records {
            var json = try rawStrings("SELECT CAST(record AS TEXT) FROM dk_records WHERE id = '\(record.id.rawValue)'")[0]
            for field in ["\"policyChangeDeferred\":false,", "\"restartDeferred\":false,", "\"stoppedWhileUnconfirmed\":false,"] {
                json = json.replacingOccurrences(of: field, with: "")
            }
            XCTAssertFalse(json.contains("Deferred"))
            try rawExecute("UPDATE dk_records SET record = CAST('\(json)' AS BLOB) WHERE id = '\(record.id.rawValue)'")
        }
        try rawExecute("UPDATE dk_schema SET version = 1")

        let migrated = try open()
        let contents = try await migrated.load()
        XCTAssertEqual(contents?.records, records.sorted { $0.id < $1.id }, "the new fields read as false")
        XCTAssertEqual(try rawStrings("SELECT CAST(version AS TEXT) FROM dk_schema"), ["\(IndexSchema.currentVersion)"])
        await migrated.close()

        // The flags round-trip once written.
        var flagged = record("paused-unconfirmed", phase: .paused)
        flagged.stoppedWhileUnconfirmed = true
        flagged.restartDeferred = true
        flagged.policyChangeDeferred = true
        let reopened = try open()
        try await reopened.apply(IndexChangeSet(upserts: [flagged], nextGeneration: 10))
        await reopened.close()
        let reread = try await open().load()
        XCTAssertEqual(reread?.records.first { $0.id == itemID("paused-unconfirmed") }, flagged)
    }

    func testEmptyDatabaseFileIsCreatedAfresh() async throws {
        try Data().write(to: fileURL)
        let store = try open()
        let contents = try await store.load()
        XCTAssertNil(contents)
        try await store.apply(IndexChangeSet(upserts: [record("a", phase: .queued)], nextGeneration: 4))
        await store.close()
        let reread = try await open().load()
        XCTAssertEqual(reread?.records.count, 1)
    }

    func testIndexReachedThroughASymbolicLinkIsRefused() async throws {
        let outside = try TemporaryDirectory("sqlite-outside")
        defer { outside.remove() }
        let target = outside.appending("other.sqlite")
        let elsewhere = try SQLiteIndexStore(fileURL: target)
        try await elsewhere.apply(IndexChangeSet(upserts: [record("a", phase: .queued)], nextGeneration: 4))
        await elsewhere.close()
        let before = try Data(contentsOf: target)

        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .storageUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: target), before, "the other database is untouched")

        // A link in place of the write-ahead log is refused too.
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: fileURL.path + "-wal"), withDestinationURL: outside.appending("log"))
        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .storageUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending("log").path))
    }

    // MARK: Competing writers

    /// Holds a write transaction on its own connection and thread: runs `changes` inside
    /// `BEGIN IMMEDIATE`, then commits once the opener is about to ask for the write lock, after
    /// `delay`, so the opener waits for the lock and acquires it only after that commit.
    private final class CompetingWriter: Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private let go = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)

        init(path: String, changes: String, delay: TimeInterval) {
            let ready = self.ready, go = self.go, done = self.done
            Thread {
                var handle: OpaquePointer?
                sqlite3_open(path, &handle)
                sqlite3_busy_timeout(handle, 10_000)
                sqlite3_exec(handle, "BEGIN IMMEDIATE; \(changes)", nil, nil, nil)
                ready.signal()
                go.wait()
                Thread.sleep(forTimeInterval: delay)
                sqlite3_exec(handle, "COMMIT", nil, nil, nil)
                sqlite3_close(handle)
                done.signal()
            }.start()
            ready.wait()
        }

        /// The opener's hook: lets the writer commit while the opener waits for the lock.
        var release: @Sendable () -> Void { { [go] in go.signal() } }

        func waitUntilCommitted() { done.wait() }
    }

    private func writeVersionOneIndex() async throws {
        let store = try open()
        try await store.apply(IndexChangeSet(upserts: everyShape(), nextGeneration: 10))
        await store.close()
        try rawExecute("UPDATE dk_schema SET version = 1")
    }

    func testNewerVersionCommittedWhileTheOpenerWaitsForTheLockIsRefused() async throws {
        try await writeVersionOneIndex()
        // Another process holds the write lock and raises the version to 3; the opener's
        // read-only inspection still sees the committed version 1.
        let writer = CompetingWriter(path: fileURL.path, changes: "UPDATE dk_schema SET version = 3;", delay: 0.3)
        XCTAssertThrowsError(try SQLiteIndexStore(fileURL: fileURL, beforeWriterLock: writer.release)) { error in
            XCTAssertEqual(error as? DownloadError, .unsupportedSchema(found: 3, supported: IndexSchema.currentVersion))
        }
        writer.waitUntilCommitted()
        XCTAssertEqual(try rawStrings("SELECT CAST(version AS TEXT) FROM dk_schema"), ["3"], "the newer version is not overwritten")
        XCTAssertEqual(try rawStrings("SELECT id FROM dk_records").count, everyShape().count)
    }

    func testRecordInvalidatedWhileTheOpenerWaitsForTheLockIsRefusedWithoutMigration() async throws {
        try await writeVersionOneIndex()
        try rawExecute("PRAGMA journal_mode = DELETE")
        XCTAssertEqual(try Data(contentsOf: fileURL)[18], 1, "rollback-journal mode before")
        // Another process makes a row disagree with its record after the inspection passed.
        let writer = CompetingWriter(path: fileURL.path, changes: "UPDATE dk_records SET generation = 7 WHERE id = 'completed';", delay: 0.3)
        XCTAssertThrowsError(try SQLiteIndexStore(fileURL: fileURL, beforeWriterLock: writer.release)) { error in
            XCTAssertEqual(error as? DownloadError, .corruptIndex)
        }
        writer.waitUntilCommitted()
        XCTAssertEqual(try rawStrings("SELECT CAST(version AS TEXT) FROM dk_schema"), ["1"], "nothing was migrated")
        XCTAssertEqual(try Data(contentsOf: fileURL)[18], 1, "the journal mode was not switched to WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-wal"))
        XCTAssertEqual(try rawStrings("SELECT CAST(generation AS TEXT) FROM dk_records WHERE id = 'completed'"), ["7"])
    }

    func testVersionOneIndexIsMigratedAfterAnUnrelatedWriterCommits() async throws {
        try await writeVersionOneIndex()
        let writer = CompetingWriter(path: fileURL.path, changes: "INSERT OR REPLACE INTO dk_globals (key, value) VALUES ('host_note', 1);", delay: 0.3)
        let store = try SQLiteIndexStore(fileURL: fileURL, beforeWriterLock: writer.release)
        writer.waitUntilCommitted()
        let contents = try await store.load()
        XCTAssertEqual(contents?.records.count, everyShape().count)
        await store.close()
        XCTAssertEqual(try rawStrings("SELECT CAST(version AS TEXT) FROM dk_schema"), ["\(IndexSchema.currentVersion)"])
        XCTAssertEqual(try rawStrings("SELECT key FROM dk_globals WHERE key = 'host_note'"), ["host_note"], "unknown globals are kept")
    }

    // MARK: Raw access

    private func rawExecute(_ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fileURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
    }

    private func rawStrings(_ sql: String) throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fileURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        }
        return result
    }
}
