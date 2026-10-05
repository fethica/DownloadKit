//
//  DownloadManagerRecoveryTests.swift
//  DownloadKitTests
//
//  Restart reconciliation, rejected index writes, inspection failures, lease handoff,
//  interrupted stops and background-wake completion.
//

import XCTest
@testable import DownloadKit

@MainActor
final class CallCounter {
    var count = 0
    nonisolated init() {}
}

final class DownloadManagerRecoveryTests: XCTestCase {

    private func restart(_ first: Harness, session: FakeTransferSession? = nil, store: InMemoryIndexStore? = nil) throws -> Harness {
        try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: store ?? first.store, session: session)
    }

    private func contents(of machine: DownloadStateMachine) -> IndexContents {
        IndexContents(nextGeneration: machine.nextGeneration, records: Array(machine.records.values))
    }

    // MARK: startup barrier

    func testCompletionBufferedBeforeStartIsAppliedInsteadOfReplacingTheAttempt() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await first.session.latestReference(for: itemID("a")))
        await manager.detach()

        let captured = path("staging/buffered")
        await first.fileSystem.putFile(first.url(captured), size: 10)
        let session = FakeTransferSession(identifier: first.sessionIdentifier, backlog: [.finished(reference, captured: captured, bytes: 10, validators: nil)])
        let second = try restart(first, session: session)
        let restarted = second.makeManager()
        try await restarted.start()

        await eventually("buffered completion applied") { await restarted.snapshot(for: itemID("a"))?.isAvailableOffline == true }
        await eventually("backlog acknowledged") { await session.acknowledged == 2 }
        let submissions = await session.submissions
        let removed = await first.fileSystem.removed
        let finalExists = await first.fileSystem.hasFile(first.url(.media(generation: reference.generation)))
        XCTAssertTrue(submissions.isEmpty, "no replacement attempt over a delivered completion")
        XCTAssertFalse(removed.contains(FakeFileSystem.key(first.url(captured))))
        XCTAssertTrue(finalExists)
    }

    func testTaskCreatedBeforeItsBindingWasCommittedIsAdopted() async throws {
        var machine = DownloadStateMachine.fresh()
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        let generation = machine.generation("a")
        XCTAssertNil(machine.record("a")?.binding, "intent committed, binding never written")
        let store = InMemoryIndexStore(contents: contents(of: machine))

        let sessionIdentifier = Harness.uniqueName("session")
        let session = FakeTransferSession(identifier: sessionIdentifier, liveTasks: [reference("a", generation: generation, task: 55)])
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session)
        let manager = harness.makeManager()
        try await manager.start()

        await eventually("backlog acknowledged") { await session.acknowledged == 1 }
        withExtendedLifetime(manager) {}
        let submissions = await session.submissions
        let stored = await store.contents?.records.first
        XCTAssertTrue(submissions.isEmpty, "the surviving task is adopted, not duplicated")
        XCTAssertEqual(stored?.binding?.taskIdentifier, 55)
        XCTAssertEqual(stored?.generation, generation)
    }

    func testUnmappedTasksAreLeftAloneAndStalePackageTasksAreCancelled() async throws {
        let ghost = reference("ghost", generation: 4, task: 901)
        let foreign = SystemTransferTask(taskIdentifier: 900, taskDescription: "host-owned task")
        let sessionIdentifier = Harness.uniqueName("session")
        let session = FakeTransferSession(identifier: sessionIdentifier, liveTasks: [ghost], unmappedTasks: [foreign])
        let harness = try Harness(sessionIdentifier: sessionIdentifier, session: session)

        try await harness.makeManager().start()

        let cancellations = await session.cancellations
        XCTAssertEqual(cancellations, [.init(taskIdentifier: 901, producingResumeData: false)])
        XCTAssertNil(foreign.reference)
    }

    func testCapturedFileRenamedBeforeTheCommitIsRecoveredOnStart() async throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/x"), bytes: 10, validators: nil))
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let harness = try Harness(store: store)
        await harness.fileSystem.putFile(harness.url(.media(generation: generation)), size: 10)

        let manager = harness.makeManager()
        try await manager.start()
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let submissions = await harness.session.submissions
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertTrue(submissions.isEmpty)
    }

    func testRestartReportsAVerifiablyAbsentCompletedFileAsMissing() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: first)
        await manager.detach()
        try await first.fileSystem.removeItem(at: first.url(.media(generation: 1)))

        let restarted = try restart(first).makeManager()
        try await restarted.start()

        let state = await restarted.state(for: itemID("a"))
        XCTAssertEqual(state, .missing)
    }

    // MARK: inspection failures

    func testInspectionFailureIsNeverTreatedAsAbsence() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: first)
        await first.fileSystem.configure(failInspection: true)

        await assertThrows(.fileAccessFailed(itemID("a"))) { _ = try await manager.localFile(for: itemID("a")) }
        await assertThrows(.fileAccessFailed(itemID("a"))) { _ = try await manager.withLocalFile(for: itemID("a")) { $0 } }

        let state = await manager.state(for: itemID("a"))
        let stored = await first.store.contents?.records.first
        let fileExists = await first.fileSystem.hasFile(first.url(.media(generation: 1)))
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertEqual(stored?.finalPath, .media(generation: 1))
        XCTAssertNotNil(stored?.integrity)
        XCTAssertTrue(fileExists)

        await manager.detach()
        let restarted = try restart(first).makeManager()
        try await restarted.start()
        let afterRestart = await restarted.state(for: itemID("a"))
        XCTAssertEqual(afterRestart, .completed(at: referenceDate), "a failed inspection at start concludes nothing")
    }

    // MARK: rejected index writes

    func testRejectedTerminalEventIsKeptAndAppliedOnceTheIndexRecovers() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)

        await harness.store.setFailWrites(true)
        let sequence = await harness.session.emit(.finished(reference, captured: captured, bytes: 10, validators: nil))
        await eventually("event kept") { await manager.engine.pendingWorkCount == 1 }

        let acknowledged = await harness.session.acknowledged ?? 0
        let capturedExists = await harness.fileSystem.hasFile(harness.url(captured))
        XCTAssertLessThan(acknowledged, sequence, "an unapplied event is never acknowledged")
        XCTAssertTrue(capturedExists)
        await assertThrows(.persistenceFailed) { try await manager.flushPendingWork() }

        await harness.store.setFailWrites(false)
        try await manager.flushPendingWork()
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let acknowledgedAfter = await harness.session.acknowledged
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertEqual(acknowledgedAfter, sequence)
    }

    func testRejectedRetryDueKeepsTheRetryAndSubmitsLater() async throws {
        let harness = try Harness(retryPolicy: RetryPolicy(baseDelay: 2), jitter: 1)
        let manager = harness.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        await manager.engine.ingest(.transfer(.failed(reference, .network(code: nil))))
        await eventually("retry timer registered") { await harness.clock.sleeperCount == 1 }

        await harness.store.setFailWrites(true)
        await harness.clock.advance(by: 2)
        await eventually("retry kept") { await manager.engine.pendingWorkCount == 1 }
        let waiting = await manager.state(for: itemID("a"))
        XCTAssertEqual(waiting, .waiting(.retryScheduled(at: referenceDate.addingTimeInterval(2))))

        await harness.store.setFailWrites(false)
        try await manager.flushPendingWork()

        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.count, 2)
    }

    func testFailedFileDeletionIsRetriedWithoutARestart() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: harness)
        await harness.fileSystem.configure(failRemove: true)
        try await manager.remove(itemID("a"))
        let removing = await manager.state(for: itemID("a"))
        XCTAssertEqual(removing, .removing)

        await harness.fileSystem.configure()
        try await manager.flushPendingWork()

        let state = await manager.state(for: itemID("a"))
        let fileExists = await harness.fileSystem.hasFile(harness.url(.media(generation: 1)))
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertFalse(fileExists)
    }

    // MARK: captured bytes across commands

    func testDeferredCaptureCompletesAfterPauseAndResume() async throws {
        let harness = try Harness()
        await harness.finalizer.setMode(.deferred)
        let manager = harness.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: harness)

        try await manager.pause(itemID("a"))
        await harness.finalizer.setMode(.finalize)
        try await manager.resume(itemID("a"))
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let submissions = await harness.session.submissions
        let generations = await harness.finalizer.requests.map(\.generation)
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertEqual(submissions.count, 1, "no new transfer over captured bytes")
        XCTAssertEqual(generations, [1, 1])
    }

    // MARK: lease handoff

    func testDetachKeepsTheRootWhileALeaseIsOutstanding() async throws {
        let first = try Harness()
        let owner = first.makeManager()
        try await owner.start()
        try await completeItem("a", manager: owner, harness: first)
        guard case .available(let lease) = try await owner.localFile(for: itemID("a")) else {
            return XCTFail("expected an available file")
        }
        try await owner.remove(itemID("a"))
        await owner.detach()

        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        await assertThrows(.ownerAlreadyActive) { try await next.start() }
        let stillThere = await first.fileSystem.hasFile(lease.url)
        XCTAssertTrue(stillThere, "the leased file outlives the detach")

        await owner.endAccess(lease)
        let afterDetachedEnd = await first.fileSystem.hasFile(lease.url)
        XCTAssertTrue(afterDetachedEnd, "a detached owner never deletes")

        try await next.start()
        let state = await next.state(for: itemID("a"))
        let gone = await first.fileSystem.hasFile(lease.url)
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertFalse(gone)
    }

    func testReleasedManagerWithAnOutstandingLeaseKeepsTheRoot() async throws {
        let first = try Harness()
        var owner: DownloadManager? = first.makeManager()
        try await owner?.start()
        try await completeItem("a", manager: try XCTUnwrap(owner), harness: first)
        let lookup = try await owner?.localFile(for: itemID("a"))
        guard case .available(let lease) = lookup else { return XCTFail("expected an available file") }
        owner = nil

        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        await assertThrows(.ownerAlreadyActive) { try await next.start() }
        withExtendedLifetime(lease) {}
    }

    // MARK: interrupted stops

    func testPauseInterruptedBeforeCancellationIsEnforcedOnRestart() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        let generation = try machine.enqueueAndBind("a", task: 101)
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let session = FakeTransferSession(identifier: sessionIdentifier, liveTasks: [reference("a", generation: generation, task: 101)])

        let manager = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session).makeManager()
        try await manager.start()

        let cancellations = await session.cancellations
        let stored = await store.contents?.records.first
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(cancellations, [.init(taskIdentifier: 101, producingResumeData: true)])
        XCTAssertNil(stored?.stoppingBinding)
        XCTAssertEqual(state, .paused(resumable: false))
    }

    func testRemovalInterruptedBeforeCancellationCancelsTheOldTaskThenFinishes() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        let generation = try machine.enqueueAndBind("a", task: 101)
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let session = FakeTransferSession(identifier: sessionIdentifier, liveTasks: [reference("a", generation: generation, task: 101)])

        let manager = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session).makeManager()
        try await manager.start()

        let cancellations = await session.cancellations
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(cancellations, [.init(taskIdentifier: 101, producingResumeData: false)])
        XCTAssertEqual(state, .notDownloaded)
    }

    func testStopWhoseTaskIsAlreadyGoneIsAcknowledgedOnRestart() async throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a", task: 101)
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        let store = InMemoryIndexStore(contents: contents(of: machine))

        let harness = try Harness(store: store)
        try await harness.makeManager().start()

        let cancellations = await harness.session.cancellations
        let stored = await store.contents?.records.first
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertNil(stored?.stoppingBinding)
        XCTAssertEqual(stored?.phase, .failed(DownloadFailure(kind: .cancelled)))
    }

    func testInProcessStopIsAcknowledgedAfterTheCancel() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))

        try await manager.pause(itemID("a"))

        let stored = await harness.store.contents?.records.first
        let entries = await harness.log.entries
        XCTAssertNil(stored?.stoppingBinding)
        XCTAssertEqual(Array(entries.suffix(3)), ["persist a", "cancel 101", "persist a"], "stop intent, cancel, then acknowledgement")
    }

    // MARK: background wake

    func testBackgroundWakeHandlerRunsOnceAfterTheWakeEventsAreApplied() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        let counter = CallCounter()
        let unrelated = CallCounter()
        let accepted = await MainActor.run {
            manager.handleBackgroundEvents(forSession: harness.sessionIdentifier) { counter.count += 1 }
        }
        let refused = await MainActor.run {
            manager.handleBackgroundEvents(forSession: "another.session") { unrelated.count += 1 }
        }
        XCTAssertTrue(accepted, "a handler is accepted before start")
        XCTAssertFalse(refused)

        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        let callsBefore = await MainActor.run { counter.count }
        XCTAssertEqual(callsBefore, 0)

        await harness.session.emit(.finished(reference, captured: captured, bytes: 10, validators: nil))
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("handler called") { await MainActor.run { counter.count } == 1 }
        let journal = await harness.store.contents?.records.first?.journal
        XCTAssertNotEqual(journal, .notStarted, "the wake's completion was committed first")

        let duplicate = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("duplicate marker applied") { await harness.session.acknowledged == duplicate }
        withExtendedLifetime(manager) {}
        let calls = await MainActor.run { counter.count }
        let unrelatedCalls = await MainActor.run { unrelated.count }
        XCTAssertGreaterThan(duplicate, marker)
        XCTAssertEqual(calls, 1, "exactly once")
        XCTAssertEqual(unrelatedCalls, 0)
    }

    // MARK: snapshot subscriptions

    func testBreakingOutOfARetainedStreamUnsubscribes() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        let stream = await manager.snapshots()

        for await _ in stream { break }

        await eventually("subscription released") { await manager.engine.subscriberCount == 0 }
        withExtendedLifetime(stream) {}
    }

    // MARK: transfer URLs

    func testTransferURLIsResolvedPerAttemptAndNeverPersisted() async throws {
        struct Signer: URLRefreshing {
            func refreshedURL(for id: DownloadID, metadata: DownloadMetadata) async throws -> URL {
                throw FakeError.injected
            }
            func transferURL(for id: DownloadID, sourceURL: URL, metadata: DownloadMetadata) async throws -> URL {
                URL(string: sourceURL.absoluteString + "?token=secret")!
            }
        }
        let harness = try Harness()
        let manager = harness.makeManager(urlRefresher: Signer())
        try await manager.start()

        try await manager.enqueue(makeRequest("a"))

        let submitted = await harness.session.submissions.first?.url.query
        let raw = await harness.store.rawData ?? Data()
        XCTAssertEqual(submitted, "token=secret")
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("secret"))
    }
}
