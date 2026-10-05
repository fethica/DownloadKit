//
//  DownloadManagerLifecycleTests.swift
//  DownloadKitTests
//
//  start(), ownership, storage root rule, schema refusal and restart reconciliation.
//

import XCTest
@testable import DownloadKit

final class DownloadManagerLifecycleTests: XCTestCase {

    func testStartCreatesTheRootLayoutAndExcludesMediaFromBackup() async throws {
        let harness = try Harness()
        try await harness.makeManager().start()

        let fs = harness.fileSystem
        let root = harness.root
        let isRootDirectory = await fs.isDirectory(root)
        let isMediaDirectory = await fs.isDirectory(root.appendingPathComponent("media"))
        let isStagingDirectory = await fs.isDirectory(root.appendingPathComponent("staging"))
        let mediaExcluded = await fs.isExcluded(root.appendingPathComponent("media"))
        let stagingExcluded = await fs.isExcluded(root.appendingPathComponent("staging"))
        let rootExcluded = await fs.isExcluded(root)
        XCTAssertTrue(isRootDirectory)
        XCTAssertTrue(isMediaDirectory)
        XCTAssertTrue(isStagingDirectory)
        XCTAssertTrue(mediaExcluded)
        XCTAssertTrue(stagingExcluded)
        XCTAssertFalse(rootExcluded, "the index stays in backup")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testCommandsBeforeStartFail() async throws {
        let manager = try Harness().makeManager()
        do {
            try await manager.enqueue(makeRequest("a"))
            XCTFail("expected notStarted")
        } catch {
            XCTAssertEqual(error as? DownloadError, .notStarted)
        }
        let lookup: LocalFileResult? = try? await manager.localFile(for: itemID("a"))
        XCTAssertNil(lookup)
    }

    func testStartingTwiceFails() async throws {
        let manager = try Harness().makeManager()
        try await manager.start()
        await assertThrows(.alreadyStarted) { try await manager.start() }
    }

    func testSecondOwnerOfTheSameRootFailsUntilTheFirstDetaches() async throws {
        let fileSystem = FakeFileSystem()
        let namespace = Harness.uniqueName("shared")
        let first = try Harness(namespace: namespace, fileSystem: fileSystem).makeManager()
        let second = try Harness(namespace: namespace, fileSystem: fileSystem).makeManager()

        try await first.start()
        await assertThrows(.ownerAlreadyActive) { try await second.start() }

        await first.detach()
        try await second.start()
    }

    func testSecondOwnerOfTheSameSessionIdentifierFails() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        let first = try Harness(sessionIdentifier: sessionIdentifier).makeManager()
        let second = try Harness(sessionIdentifier: sessionIdentifier).makeManager()

        try await first.start()
        await assertThrows(.ownerAlreadyActive) { try await second.start() }
    }

    func testUnavailableStorageHasNoFallbackAndStartCanBeRetried() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()

        await harness.fileSystem.configure(failApplicationSupport: true)
        await assertThrows(.storageUnavailable) { try await manager.start() }

        await harness.fileSystem.configure(failCreateDirectory: true)
        await assertThrows(.storageUnavailable) { try await manager.start() }

        await harness.fileSystem.configure()
        try await manager.start()
    }

    func testNewerSchemaIsRefusedWithoutReset() async throws {
        let store = InMemoryIndexStore(contents: IndexContents(schemaVersion: 999, nextGeneration: 7))
        let before = await store.rawData
        let manager = try Harness(store: store).makeManager()

        await assertThrows(.unsupportedSchema(found: 999, supported: IndexSchema.currentVersion)) { try await manager.start() }

        let after = await store.rawData
        let writes = await store.applyCount
        XCTAssertEqual(before, after)
        XCTAssertEqual(writes, 0)
    }

    func testCorruptIndexIsRefusedWithoutReset() async throws {
        let store = InMemoryIndexStore()
        await store.setCorrupt()
        let manager = try Harness(store: store).makeManager()

        await assertThrows(.corruptIndex) { try await manager.start() }
        let writes = await store.applyCount
        XCTAssertEqual(writes, 0)
    }

    func testUnavailableTransportFailsStart() async throws {
        let manager = try Harness(failingTransport: true).makeManager()
        await assertThrows(.transportUnavailable) { try await manager.start() }
    }

    func testRestartResubmitsOnlyIntentWhoseTaskIsGone() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        try await manager.enqueue(makeRequest("b"))
        let survivingTask = await first.session.latestReference(for: itemID("a"))
        await manager.detach()

        let newSession = FakeTransferSession(identifier: first.sessionIdentifier, liveTasks: [try XCTUnwrap(survivingTask)])
        let second = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store, session: newSession)
        try await second.makeManager().start()

        await eventually("orphan resubmitted after the backlog") { await newSession.submissions.count == 1 }
        let resubmitted = await newSession.submissions
        XCTAssertEqual(resubmitted.map(\.itemID), [itemID("b")])
        XCTAssertEqual(resubmitted.first?.generation, 3, "generations continue from the index")
    }

    func testRestartKeepsThePersistedDefaultPolicy() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await manager.setDefaultPolicy(.anyNetwork)
        await manager.detach()

        let second = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store)
        let restarted = second.makeManager()
        try await restarted.start()

        let policy = await restarted.defaultPolicy()
        XCTAssertEqual(policy, .anyNetwork)
        XCTAssertEqual(second.configuration.defaultPolicy, .unmeteredOnly)
    }

    func testRestartFiresOverdueRetries() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await first.session.latestReference(for: itemID("a")))
        await manager.engine.ingest(.transfer(.failed(reference, .network(code: nil))))
        await manager.detach()

        let clock = ManualClock(referenceDate.addingTimeInterval(3600))
        let newSession = FakeTransferSession(identifier: first.sessionIdentifier)
        let second = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store, session: newSession, clock: clock)
        let restarted = second.makeManager()
        try await restarted.start()
        await restarted.engine.fireDueRetries()

        let submissions = await newSession.submissions
        XCTAssertEqual(submissions.count, 1)
        let state = await restarted.state(for: itemID("a"))
        XCTAssertEqual(state, .queued)
    }

    func testInterruptedRemovalFinishesOnRestart() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: first)
        await first.fileSystem.configure(failRemove: true)
        try await manager.remove(itemID("a"))
        let removing = await manager.state(for: itemID("a"))
        XCTAssertEqual(removing, .removing)
        await manager.detach()

        await first.fileSystem.configure()
        let second = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store)
        let restarted = second.makeManager()
        try await restarted.start()

        let state = await restarted.state(for: itemID("a"))
        let fileExists = await first.fileSystem.hasFile(first.url(.media(generation: 1)))
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertFalse(fileExists)
    }

    func testDetachEndsSnapshotStreamsAndKeepsTransfers() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        var iterator = await manager.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)

        await manager.detach()

        let afterDetach = await iterator.next()
        XCTAssertNil(afterDetach, "detaching ends the stream")
        let cancellations = await harness.session.cancellations
        XCTAssertTrue(cancellations.isEmpty, "detaching never cancels transfers")
        await assertThrows(.notStarted) { try await manager.pause(itemID("a")) }
    }
}

// MARK: Shared helpers

func assertThrows(
    _ expected: DownloadError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? DownloadError, expected, file: file, line: line)
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// Drives `raw` to completion through the session event stream and the fake finaliser.
func completeItem(_ raw: String, size: Int64 = 10, manager: DownloadManager, harness: Harness) async throws {
    try await manager.enqueue(makeRequest(raw))
    let latest = await harness.session.latestReference(for: itemID(raw))
    let reference = try XCTUnwrap(latest)
    let captured = path("staging/\(raw)-\(reference.generation)")
    await harness.fileSystem.putFile(harness.url(captured), size: size)
    await manager.engine.ingest(.transfer(.finished(reference, captured: captured, bytes: size, validators: nil)))
    await settle(manager)
}

/// Waits until no finalisation is running, so its result has been applied.
func settle(_ manager: DownloadManager) async {
    await eventually("finalisation settled") { await manager.engine.finalizationsInFlight == 0 }
}
