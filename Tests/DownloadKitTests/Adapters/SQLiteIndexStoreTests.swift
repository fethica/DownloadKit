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
        try rawExecute("UPDATE dk_schema SET version = 2")
        let before = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? DownloadError, .unsupportedSchema(found: 2, supported: 1))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(try rawStrings("SELECT CAST(version AS TEXT) FROM dk_schema"), ["2"], "the version is not reset")
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
