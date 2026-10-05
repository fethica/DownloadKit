//
//  EndToEndTests.swift
//  DownloadKitTests
//
//  The manager on the production adapters: the URLSession transport (foreground, URLProtocol
//  fixture), the SQLite index, the local file system and the file finaliser, on a temporary
//  root. Crash-point fixtures write the on-disk state a crash leaves behind and start a fresh
//  manager on it.
//

import CryptoKit
import Foundation
import XCTest
@testable import DownloadKit

/// Captures the index store a manager opens, to inject write failures.
actor StoreHolder {
    private(set) var store: SQLiteIndexStore?

    func set(_ store: SQLiteIndexStore) {
        self.store = store
    }
}

/// Forwards everything to a real session except acknowledgements, like a process that ended
/// after committing events and before acknowledging them.
struct AcknowledgementDroppingTransport: TransferSessionFactory {
    let base: URLSessionTransport

    struct Session: TransferSession {
        let base: any TransferSession
        var identifier: String { base.identifier }
        var events: AsyncStream<TransferSessionEvent> { base.events }
        func submit(_ submission: TransferSubmission) async throws -> Int { try await base.submit(submission) }
        func cancel(taskIdentifier: Int, producingResumeData: Bool) async { await base.cancel(taskIdentifier: taskIdentifier, producingResumeData: producingResumeData) }
        func systemTasks() async -> [SystemTransferTask] { await base.systemTasks() }
        func acknowledge(through sequence: UInt64) async {}
    }

    func makeSession(identifier: String, storageRoot: URL) async throws -> any TransferSession {
        Session(base: try await base.makeSession(identifier: identifier, storageRoot: storageRoot))
    }
}

func isCompletedState(_ state: DownloadState) -> Bool {
    if case .completed = state { return true }
    return false
}

func directoryEntries(_ url: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
}

struct Refresher: URLRefreshing {
    let url: URL

    func refreshedURL(for id: DownloadID, metadata: DownloadMetadata) async throws -> URL { url }
}

final class EndToEndTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var transports: [URLSessionTransport] = []
    private var managers: [DownloadManager] = []
    private let namespace = Harness.uniqueName("ns")
    private let sessionIdentifier = Harness.uniqueName("session")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("end-to-end")
    }

    override func tearDown() async throws {
        for manager in managers { await manager.detach() }
        managers = []
        for transport in transports { await transport.invalidate(cancellingTasks: true) }
        transports = []
        directory.remove()
    }

    private var applicationSupport: URL { directory.appending("Application Support") }
    private var root: URL { applicationSupport.appendingPathComponent(namespace, isDirectory: true) }
    private func url(_ path: RelativePath) -> URL { root.appendingPathComponent(path.rawValue) }

    private func transport() -> URLSessionTransport {
        let transport = URLSessionTransport.stubbed(sessionNetworkAccess: .anyNetwork)
        transports.append(transport)
        return transport
    }

    private func manager(
        transport: any TransferSessionFactory,
        fileSystem: (any DownloadFileSystem)? = nil,
        holder: StoreHolder? = nil,
        refresher: (any URLRefreshing)? = nil
    ) throws -> DownloadManager {
        let configuration = try DownloadConfiguration(
            storageScope: StorageScope(namespace: namespace),
            sessionIdentifier: sessionIdentifier,
            snapshotInterval: 0,
            reconciliationTimeout: 10,
            dependencies: DownloadDependencies(
                transport: transport,
                makeIndexStore: { root in
                    let store = try SQLiteIndexStore(fileURL: root.appendingPathComponent(SQLiteIndexStore.fileName))
                    await holder?.set(store)
                    return store
                },
                fileSystem: fileSystem ?? LocalFileSystem(applicationSupportDirectory: applicationSupport)
            )
        )
        let manager = DownloadManager(configuration: configuration, urlRefresher: refresher)
        managers.append(manager)
        return manager
    }

    private func waitFor(_ manager: DownloadManager, _ id: DownloadID, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @Sendable (DownloadState) -> Bool) async {
        await realTimeEventually(message, timeout: 15, file: file, line: line) { condition(await manager.state(for: id)) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func entries(_ directory: String) -> [String] {
        directoryEntries(root.appendingPathComponent(directory))
    }

    private func request(_ raw: String, _ path: String, size: Int = 4_096, expectedLength: Int64? = nil, checksum: ContentChecksum? = nil) -> DownloadRequest {
        DownloadRequest(id: itemID(raw), url: StubRoute.url(path, size: size), revision: ContentRevision("r1"), expectedLength: expectedLength, checksum: checksum, policy: .anyNetwork)
    }

    // MARK: Transfers

    func testDownloadIsValidatedCommittedAndServedOfflineAcrossARestart() async throws {
        let size = 300_000
        let body = StubRoute.body(size: size)
        let transport = transport()
        let first = try manager(transport: transport)
        try await first.start()
        let id = itemID("episode-1")
        try await first.enqueue(request("episode-1", "/ok", size: size, expectedLength: Int64(size), checksum: ContentChecksum(hexDigest: Self.sha256(body))))
        await waitFor(first, id, "completed", isCompletedState)

        guard case .available(let lease) = try await first.localFile(for: id) else { return XCTFail("no local file") }
        XCTAssertEqual(try Data(contentsOf: lease.url), body)
        XCTAssertEqual(lease.url.lastPathComponent, "item-1.mp3")
        XCTAssertEqual(entries("staging"), [], "the captured file was renamed")
        let unknown = try await first.unreferencedFiles()
        XCTAssertEqual(unknown, [])
        await first.endAccess(lease)

        let media = try root.appendingPathComponent("media").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        let staging = try root.appendingPathComponent("staging").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        let index = try root.appendingPathComponent(SQLiteIndexStore.fileName).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(media, true)
        XCTAssertEqual(staging, true)
        XCTAssertEqual(index, false, "the index is kept in backups")
        await first.detach()

        let second = try manager(transport: transport)
        try await second.start()
        let restored = await second.state(for: id)
        XCTAssertTrue(isCompletedState(restored))
        guard case .available(let again) = try await second.localFile(for: id) else { return XCTFail("not served after restart") }
        XCTAssertEqual(try Data(contentsOf: again.url), body)
        await second.endAccess(again)
    }

    func testChecksumMismatchIsNeverCompleted() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/ok", size: 50_000, checksum: ContentChecksum(hexDigest: String(repeating: "a", count: 64))))
        await waitFor(manager, id, "integrity failure") { $0 == .failed(DownloadFailure(kind: .integrity)) }
        let lookup = try await manager.localFile(for: id)
        XCTAssertEqual(lookup, .unavailable(.failed(DownloadFailure(kind: .integrity))))
        let staging = root.appendingPathComponent("staging")
        await realTimeEventually("the rejected capture was deleted") { directoryEntries(staging).isEmpty }
        XCTAssertEqual(entries("media"), [])
    }

    func testErrorPageServedAsSuccessIsNeverCompleted() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        try await manager.enqueue(request("a", "/html"))
        await waitFor(manager, itemID("a"), "invalid response") { $0 == .failed(DownloadFailure(kind: .invalidResponse)) }
        XCTAssertEqual(entries("staging"), [])
        XCTAssertEqual(entries("media"), [])
    }

    func testTransientFailureSchedulesARetryHonouringRetryAfter() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/unavailable"))
        await waitFor(manager, id, "retry scheduled") {
            if case .waiting(.retryScheduled) = $0 { return true }
            return false
        }
        let snapshot = try await XCTUnwrapAsync(await manager.snapshot(for: id))
        XCTAssertEqual(snapshot.automaticRetryCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.retryAt).timeIntervalSinceNow, 100, "Retry-After: 120 raised the delay")
        try await manager.cancel(id)
    }

    func testMissingResourceFailsPermanently() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        try await manager.enqueue(request("a", "/missing"))
        await waitFor(manager, itemID("a"), "permanent failure") { $0 == .failed(DownloadFailure(kind: .http, httpStatus: 404)) }
    }

    func testExpiredURLFailsAsUnauthorizedAndRetryUsesTheRefreshedURL() async throws {
        let manager = try manager(transport: transport(), refresher: Refresher(url: StubRoute.url("/ok", size: 2_048)))
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/expired"))
        await waitFor(manager, id, "unauthorized") { $0 == .failed(DownloadFailure(kind: .unauthorized, httpStatus: 403)) }
        try await manager.retry(id)
        await waitFor(manager, id, "completed after refresh", isCompletedState)
    }

    func testDeniedWriteAtCaptureFailsAsStorage() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path) }
        try await manager.enqueue(request("a", "/ok"))
        await waitFor(manager, itemID("a"), "storage failure") { $0 == .failed(DownloadFailure(kind: .storage)) }
    }

    func testCancelBeforeTheFirstByteNeverCompletes() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/slow"))
        await realTimeEventually("the request arrived") { slowRequestHasArrived() }
        // The cancel is committed before the task is cancelled; release the fixture only then,
        // so the system's cancellation does not wait on a held request.
        let cancelling = Task { try await manager.cancel(id) }
        await waitFor(manager, id, "cancelled") { $0 == .failed(DownloadFailure(kind: .cancelled)) }
        slowFirstByteGate.signal()
        try await cancelling.value
        let state = await manager.state(for: id)
        XCTAssertEqual(state, .failed(DownloadFailure(kind: .cancelled)))
        XCTAssertEqual(entries("media"), [])
    }

    // MARK: Offline lookup

    func testExternallyDeletedFileBecomesMissing() async throws {
        let transport = transport()
        let first = try manager(transport: transport)
        try await first.start()
        try await first.enqueue(request("a", "/ok"))
        try await first.enqueue(request("b", "/ok"))
        await waitFor(first, itemID("a"), "a completed", isCompletedState)
        await waitFor(first, itemID("b"), "b completed", isCompletedState)

        guard case .available(let lease) = try await first.localFile(for: itemID("a")) else { return XCTFail("no file") }
        await first.endAccess(lease)
        try FileManager.default.removeItem(at: lease.url)
        let lookup = try await first.localFile(for: itemID("a"))
        XCTAssertEqual(lookup, .unavailable(.missing))
        let missing = await first.state(for: itemID("a"))
        XCTAssertEqual(missing, .missing)

        // Deleted while no manager runs: found at start.
        guard case .available(let other) = try await first.localFile(for: itemID("b")) else { return XCTFail("no file") }
        await first.endAccess(other)
        await first.detach()
        try FileManager.default.removeItem(at: other.url)
        let second = try manager(transport: transport)
        try await second.start()
        let restored = await second.state(for: itemID("b"))
        XCTAssertEqual(restored, .missing)
    }

    func testProtectedFileIsNeverReportedMissing() async throws {
        let faulty = FaultyFileSystem(base: LocalFileSystem(applicationSupportDirectory: applicationSupport))
        let manager = try manager(transport: transport(), fileSystem: faulty)
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/ok"))
        await waitFor(manager, id, "completed", isCompletedState)

        await faulty.fail(.inspect, with: .fileProtection)
        do {
            _ = try await manager.localFile(for: id)
            XCTFail("a protected file was looked up")
        } catch {
            XCTAssertEqual(error as? DownloadError, .fileAccessFailed(id))
        }
        let state = await manager.state(for: id)
        XCTAssertTrue(isCompletedState(state), "an inspection failure changes nothing")
    }

    func testLeaseKeepsTheFileThroughRemoval() async throws {
        let manager = try manager(transport: transport())
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/ok"))
        await waitFor(manager, id, "completed", isCompletedState)
        guard case .available(let lease) = try await manager.localFile(for: id) else { return XCTFail("no file") }

        try await manager.remove(id)
        let removing = await manager.state(for: id)
        XCTAssertEqual(removing, .removing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path), "a leased file stays")

        await manager.endAccess(lease)
        await waitFor(manager, id, "removed") { $0 == .notDownloaded }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
    }

    // MARK: Crash points

    private func seed(_ records: [IndexRecord], nextGeneration: UInt64) async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        let store = try SQLiteIndexStore(fileURL: root.appendingPathComponent(SQLiteIndexStore.fileName))
        try await store.apply(IndexChangeSet(upserts: records, nextGeneration: nextGeneration))
        await store.close()
    }

    private func record(_ raw: String, phase: RecordPhase, journal: FinalizationJournal, bytes: Int64, checksum: ContentChecksum?, staging: RelativePath? = path("staging/capture"), destination: RelativePath? = path("media/item-1.mp3"), finalPath: RelativePath? = nil, integrity: IntegrityRecord? = nil) -> IndexRecord {
        IndexRecord(
            unchecked: itemID(raw),
            request: RequestIdentity(sourceURL: StubRoute.url("/ok"), revision: ContentRevision("r1"), expectedLength: bytes, checksum: checksum),
            metadata: DownloadMetadata(), policy: .anyNetwork, phase: phase, generation: 1, automaticRetryCount: 0, retryAt: nil,
            binding: nil, stoppingBinding: nil, bytesWritten: bytes, expectedBytes: bytes,
            validators: ResponseValidators(entityTag: "\"v1\"", statusCode: 200, mediaType: "audio/mpeg"), integrity: integrity,
            journal: journal, stagingPath: staging, finalizationDestination: destination, finalPath: finalPath, resumeDataPath: nil,
            createdAt: referenceDate, updatedAt: referenceDate
        )
    }

    private func quietSession() -> FakeTransferSessionFactory {
        FakeTransferSessionFactory(session: FakeTransferSession(identifier: sessionIdentifier))
    }

    func testCrashAfterCaptureBeforeValidationOrRenameIsFinalisedOnRestart() async throws {
        // Capture committed; the process ended before (or during) validation, so before the
        // rename. Validation is not journaled: both windows leave this same state.
        let body = mediaBytes(80_000)
        try await seed([record("a", phase: .active, journal: .captured, bytes: Int64(body.count), checksum: ContentChecksum(hexDigest: Self.sha256(body)))], nextGeneration: 2)
        try writeFile(url(path("staging/capture")), body)

        let manager = try manager(transport: quietSession())
        try await manager.start()
        await waitFor(manager, itemID("a"), "recovered", isCompletedState)
        XCTAssertEqual(try Data(contentsOf: url(path("media/item-1.mp3"))), body)
        XCTAssertEqual(entries("staging"), [])
    }

    func testCrashAfterCaptureWithBadBytesIsRejectedOnRestart() async throws {
        let body = mediaBytes(80_000)
        try await seed([record("a", phase: .active, journal: .captured, bytes: Int64(body.count), checksum: ContentChecksum(hexDigest: String(repeating: "b", count: 64)))], nextGeneration: 2)
        try writeFile(url(path("staging/capture")), body)

        let manager = try manager(transport: quietSession())
        try await manager.start()
        await waitFor(manager, itemID("a"), "rejected") { $0 == .failed(DownloadFailure(kind: .integrity)) }
        let staging = root.appendingPathComponent("staging")
        await realTimeEventually("rejected bytes deleted") { directoryEntries(staging).isEmpty }
        XCTAssertEqual(entries("media"), [], "nothing unvalidated was renamed")
    }

    func testCrashBetweenRenameAndCommitIsRecoveredOnRestart() async throws {
        let body = mediaBytes(80_000)
        try await seed([record("a", phase: .active, journal: .captured, bytes: Int64(body.count), checksum: ContentChecksum(hexDigest: Self.sha256(body)))], nextGeneration: 2)
        // Renamed, not committed: nothing is left in staging, the destination holds the file.
        try writeFile(url(path("media/item-1.mp3")), body)

        let manager = try manager(transport: quietSession())
        try await manager.start()
        await waitFor(manager, itemID("a"), "recovered", isCompletedState)
        guard case .available(let lease) = try await manager.localFile(for: itemID("a")) else { return XCTFail("not served") }
        XCTAssertEqual(lease.url.lastPathComponent, "item-1.mp3")
        await manager.endAccess(lease)
    }

    func testCommittedRecordWhoseFileDisappearedIsMissingOnRestart() async throws {
        try await seed([record("a", phase: .completed(at: referenceDate), journal: .committed, bytes: 10, checksum: nil, staging: nil, destination: nil, finalPath: path("media/item-1.mp3"), integrity: IntegrityRecord(verifiedLength: 10))], nextGeneration: 2)
        let manager = try manager(transport: quietSession())
        try await manager.start()
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(state, .missing)
    }

    func testCrashBetweenCommitAndAcknowledgementReplaysIdempotently() async throws {
        let first = try manager(transport: AcknowledgementDroppingTransport(base: transport()))
        try await first.start()
        let id = itemID("a")
        try await first.enqueue(request("a", "/ok", size: 20_000))
        await waitFor(first, id, "completed", isCompletedState)
        guard case .available(let lease) = try await first.localFile(for: id) else { return XCTFail("no file") }
        let bytes = try Data(contentsOf: lease.url)
        await first.endAccess(lease)
        await first.detach()
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: sessionIdentifier)
        XCTAssertFalse(inbox.storedEvents().isEmpty, "the completion is still unacknowledged")

        // Relaunch: a new transport replays the completion with its original sequence number.
        let second = try manager(transport: transport())
        try await second.start()
        await realTimeEventually("the replay was applied and acknowledged") { inbox.storedEvents().isEmpty }
        let state = await second.state(for: id)
        XCTAssertTrue(isCompletedState(state))
        guard case .available(let again) = try await second.localFile(for: id) else { return XCTFail("not served after replay") }
        XCTAssertEqual(try Data(contentsOf: again.url), bytes)
        await second.endAccess(again)
        let unknown = try await second.unreferencedFiles()
        XCTAssertEqual(unknown, [])
    }

    func testInterruptedIndexWriteKeepsTheCaptureUncommittedUntilRetried() async throws {
        let holder = StoreHolder()
        let session = FakeTransferSession(identifier: sessionIdentifier)
        let manager = try manager(transport: FakeTransferSessionFactory(session: session), holder: holder)
        try await manager.start()
        let id = itemID("a")
        try await manager.enqueue(request("a", "/ok"))
        let reference = try await XCTUnwrapAsync(await session.latestReference(for: id))
        let body = mediaBytes(4_096)
        try writeFile(url(path("staging/capture")), body)

        let store = try await XCTUnwrapAsync(await holder.store)
        await store.injectFailure(afterStatements: 0)
        await session.emit(.finished(reference, captured: path("staging/capture"), bytes: Int64(body.count), validators: ResponseValidators(statusCode: 200, mediaType: "audio/mpeg")))
        await realTimeEventually("the rejected write is retained") { await manager.engine.pendingWorkCount > 0 }
        let stored = try await store.load()
        let record = try XCTUnwrap(stored?.records.first { $0.id == id })
        XCTAssertEqual(record.journal, .notStarted, "nothing was committed")
        let state = await manager.state(for: id)
        XCTAssertFalse(isCompletedState(state))

        try await manager.flushPendingWork()
        await waitFor(manager, id, "completed after the retry", isCompletedState)
        let committed = try await store.load()
        XCTAssertEqual(committed?.records.first { $0.id == id }?.journal, .committed)
    }
}
