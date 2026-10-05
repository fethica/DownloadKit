//
//  DownloadManagerOwnershipTests.swift
//  DownloadKitTests
//
//  Restart with an initially allowed path, file workers as ownership claims, leases ended
//  through a successor, replay before recovered finalisation, exact stop identity, the
//  reconciliation fence and wake budget, persisted cleanup intent, the completion/stop
//  linearisation point, restart commands on unconfirmed attempts, worker lifetime after the
//  manager is released, and deadlines that hold while an index write is suspended.
//

import XCTest
@testable import DownloadKit

final class DownloadManagerOwnershipTests: XCTestCase {

    private let cellular = NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true)
    private let wifi = NetworkPathStatus(isSatisfied: true)

    private func contents(of machine: DownloadStateMachine) -> IndexContents {
        IndexContents(nextGeneration: machine.nextGeneration, records: Array(machine.records.values), cleanupPaths: Array(machine.cleanup))
    }

    private func restart(_ first: Harness, session: FakeTransferSession? = nil) throws -> Harness {
        try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store, session: session)
    }

    /// An item whose intent was committed while the policy refused the path; its task binding
    /// was never written.
    private func unboundWaitingIndex(session: String) throws -> (InMemoryIndexStore, UInt64) {
        var machine = DownloadStateMachine.fresh(session: session)
        _ = machine.handle(.pathChanged(cellular), now: referenceDate, jitter: 0)
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        XCTAssertEqual(machine.phase("a"), .waiting(.networkPolicy))
        XCTAssertNil(machine.record("a")?.binding)
        return (InMemoryIndexStore(contents: contents(of: machine)), machine.generation("a"))
    }

    /// A captured, not yet finalised item, as saved before the session's event was acknowledged.
    private func capturedIndex(session: String) throws -> (InMemoryIndexStore, TransferEvent, UInt64) {
        var machine = DownloadStateMachine.fresh(session: session)
        let generation = try machine.enqueueAndBind("a")
        let finished = TransferEvent.finished(reference("a", generation: generation), captured: path("staging/x"), bytes: 10, validators: nil)
        _ = machine.send(finished)
        return (InMemoryIndexStore(contents: contents(of: machine)), finished, generation)
    }

    /// Starts `a`, delivers its completion and waits until the finaliser is suspended.
    private func suspendFinalisation(_ harness: Harness, manager: DownloadManager, gate: FakeFinalizer.Gate) async throws -> TransferTaskReference {
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        await harness.finalizer.setGate(gate)
        await harness.session.emit(.finished(reference, captured: captured, bytes: 10, validators: nil))
        await eventually("finaliser suspended") { await harness.finalizer.suspendedCount == 1 }
        return reference
    }

    // MARK: restart with an initially allowed path

    func testInitiallyAllowedPathAdoptsTheLiveTaskInsteadOfReplacingIt() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        let (store, generation) = try unboundWaitingIndex(session: sessionIdentifier)
        let session = FakeTransferSession(identifier: sessionIdentifier, liveTasks: [reference("a", generation: generation, task: 55)])
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session, pathSource: FakePathSource(wifi))
        let manager = harness.makeManager()

        try await manager.start()
        await eventually("backlog applied") { await session.acknowledged == 1 }

        let submissions = await session.submissions
        let cancellations = await session.cancellations
        let stored = await store.contents?.records.first
        let state = await manager.state(for: itemID("a"))
        XCTAssertTrue(submissions.isEmpty, "the allowed path never replaces an attempt whose task may exist")
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertEqual(stored?.generation, generation)
        XCTAssertEqual(stored?.binding?.taskIdentifier, 55)
        XCTAssertEqual(state, .queued)
    }

    func testInitiallyAllowedPathAppliesTheBufferedCompletionInsteadOfReplacingIt() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        let (store, generation) = try unboundWaitingIndex(session: sessionIdentifier)
        let captured = path("staging/buffered")
        let session = FakeTransferSession(identifier: sessionIdentifier, backlog: [.finished(reference("a", generation: generation, task: 55), captured: captured, bytes: 10, validators: nil)])
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session, pathSource: FakePathSource(wifi))
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        let manager = harness.makeManager()

        try await manager.start()
        await eventually("buffered completion applied") { await manager.state(for: itemID("a")) == .completed(at: referenceDate) }

        let submissions = await session.submissions
        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: generation)))
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(finalExists, "the buffered capture was finalised, not deleted as stale")
    }

    // MARK: file workers as ownership claims

    func testRemovalBeforeRenameWaitsForTheFinaliser() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        _ = try await suspendFinalisation(harness, manager: manager, gate: .beforeRename)

        try await manager.remove(itemID("a"))
        let removing = await manager.state(for: itemID("a"))
        let stored = await harness.store.contents?.records.first
        XCTAssertEqual(removing, .removing, "removal waits while the worker can still create a file")
        XCTAssertTrue(stored?.ownedPaths.contains(.media(generation: 1)) == true, "the planned destination is persisted with the tombstone")

        await harness.finalizer.release()
        await eventually("removal finished") { await manager.state(for: itemID("a")) == .notDownloaded }

        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: 1)))
        let stagingExists = await harness.fileSystem.hasFile(harness.url(path("staging/a")))
        XCTAssertFalse(finalExists)
        XCTAssertFalse(stagingExists)
    }

    func testRemovalAfterRenameDeletesTheRenamedFile() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        _ = try await suspendFinalisation(harness, manager: manager, gate: .afterRename)
        let renamed = await harness.fileSystem.hasFile(harness.url(.media(generation: 1)))
        XCTAssertTrue(renamed)

        try await manager.remove(itemID("a"))
        await harness.finalizer.release()
        await eventually("removal finished") { await manager.state(for: itemID("a")) == .notDownloaded }

        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: 1)))
        XCTAssertFalse(finalExists, "no media file survives the removal of its item")
    }

    func testDetachWaitsForTheFinaliserBeforeANewOwnerStarts() async throws {
        let first = try Harness()
        let owner = first.makeManager()
        try await owner.start()
        _ = try await suspendFinalisation(first, manager: owner, gate: .beforeRename)

        let detaching = Task { await owner.detach() }
        await eventually("detach step ran") { await owner.engine.isDetached }
        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        await assertThrows(.ownerAlreadyActive) { try await next.start() }

        await first.finalizer.release()
        await detaching.value
        try await next.start()
        await settle(next)

        let state = await next.state(for: itemID("a"))
        let finalExists = await first.fileSystem.hasFile(first.url(.media(generation: 1)))
        XCTAssertEqual(state, .completed(at: referenceDate), "the new owner recovers the worker's rename")
        XCTAssertTrue(finalExists)
    }

    // MARK: leases across owners

    func testLeaseOfAReleasedManagerEndsThroughItsSuccessor() async throws {
        let first = try Harness()
        var owner: DownloadManager? = first.makeManager()
        try await owner?.start()
        try await completeItem("a", manager: try XCTUnwrap(owner), harness: first)
        let lookup = try await owner?.localFile(for: itemID("a"))
        guard case .available(let lease) = lookup else { return XCTFail("expected an available file") }
        owner = nil

        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        await assertThrows(.ownerAlreadyActive) { try await next.start() }

        await next.endAccess(lease)
        await next.endAccess(lease)
        try await next.start()

        let state = await next.state(for: itemID("a"))
        XCTAssertEqual(state, .completed(at: referenceDate))
        withExtendedLifetime(lease) {}
    }

    // MARK: replay before recovered finalisation

    func testReplayedCaptureThenSuccessfulRecoveredValidation() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        let (store, finished, generation) = try capturedIndex(session: sessionIdentifier)
        let session = FakeTransferSession(identifier: sessionIdentifier, backlog: [finished])
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session)
        await harness.fileSystem.putFile(harness.url(path("staging/x")), size: 10)
        let manager = harness.makeManager()

        try await manager.start()
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let acknowledged = await session.acknowledged
        let requests = await harness.finalizer.requests.count
        let submissions = await session.submissions
        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: generation)))
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertEqual(acknowledged, 2)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(finalExists)
    }

    func testReplayedCaptureThenFailedRecoveredValidation() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        let (store, finished, generation) = try capturedIndex(session: sessionIdentifier)
        let session = FakeTransferSession(identifier: sessionIdentifier, backlog: [finished])
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session)
        await harness.fileSystem.putFile(harness.url(path("staging/x")), size: 10)
        await harness.finalizer.setMode(.fail(.integrity))
        let manager = harness.makeManager()

        try await manager.start()
        await settle(manager)

        let stored = await store.contents?.records.first
        let stagingExists = await harness.fileSystem.hasFile(harness.url(path("staging/x")))
        XCTAssertEqual(stored?.phase, .failed(DownloadFailure(kind: .integrity)))
        XCTAssertEqual(stored?.journal, .rejected)
        XCTAssertNil(stored?.stagingPath)
        XCTAssertFalse(stagingExists)

        try await manager.retry(itemID("a"))
        let submissions = await session.submissions
        let requests = await harness.finalizer.requests.count
        XCTAssertEqual(submissions.count, 1, "retry starts a fresh transfer")
        XCTAssertGreaterThan(submissions.first?.generation ?? 0, generation)
        XCTAssertEqual(requests, 1)
    }

    func testRecoveredFailureWinningTheRaceNeverRevivesTheCapture() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        let (store, finished, generation) = try capturedIndex(session: sessionIdentifier)
        let session = FakeTransferSession(identifier: sessionIdentifier, deliversBacklogMarker: false)
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session, reconciliationTimeout: 5)
        await harness.fileSystem.putFile(harness.url(path("staging/x")), size: 10)
        await harness.finalizer.setMode(.fail(.integrity))
        let manager = harness.makeManager()

        try await manager.start()
        let early = await harness.finalizer.requests.count
        XCTAssertEqual(early, 0, "recovered finalisation waits for the startup replay")

        await harness.clock.advance(by: 5)
        await settle(manager)
        let failed = await manager.state(for: itemID("a"))
        XCTAssertEqual(failed, .failed(DownloadFailure(kind: .integrity)))

        let sequence = await session.emit(finished)
        await eventually("late replay applied") { await session.acknowledged == sequence }

        let stored = await store.contents?.records.first
        XCTAssertEqual(stored?.journal, .rejected, "the replay does not capture deleted bytes again")
        XCTAssertNil(stored?.stagingPath)
        XCTAssertEqual(stored?.phase, .failed(DownloadFailure(kind: .integrity)))

        try await manager.retry(itemID("a"))
        let submissions = await session.submissions
        let requests = await harness.finalizer.requests.count
        XCTAssertEqual(submissions.map(\.generation).count, 1)
        XCTAssertGreaterThan(submissions.first?.generation ?? 0, generation)
        XCTAssertEqual(requests, 1)
    }

    // MARK: exact stop identity

    func testPendingStopLeavesAnUnmappedTaskWithTheSameNumberAlone() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        try machine.enqueueAndBind("a", task: 101)
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let foreign = SystemTransferTask(taskIdentifier: 101, taskDescription: "host-owned task")
        let session = FakeTransferSession(identifier: sessionIdentifier, unmappedTasks: [foreign])

        let manager = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session).makeManager()
        try await manager.start()

        let cancellations = await session.cancellations
        let stored = await store.contents?.records.first
        XCTAssertTrue(cancellations.isEmpty, "a foreign task is never cancelled")
        XCTAssertNil(stored?.stoppingBinding, "the old stop is acknowledged")
    }

    func testPendingStopLeavesAnotherItemsTaskWithTheSameNumberAlone() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        try machine.enqueueAndBind("a", task: 101)
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        _ = try machine.handle(.enqueue(makeRequest("b")), now: referenceDate)
        let generationB = machine.generation("b")
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let session = FakeTransferSession(identifier: sessionIdentifier, liveTasks: [reference("b", generation: generationB, task: 101)])

        let manager = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session).makeManager()
        try await manager.start()
        await eventually("backlog applied") { await session.acknowledged == 1 }
        withExtendedLifetime(manager) {}

        let cancellations = await session.cancellations
        let records = await store.contents?.records ?? []
        let a = records.first { $0.id == itemID("a") }
        let b = records.first { $0.id == itemID("b") }
        XCTAssertTrue(cancellations.isEmpty, "the reused number names another attempt")
        XCTAssertNil(a?.stoppingBinding)
        XCTAssertEqual(b?.binding?.taskIdentifier, 101)
        XCTAssertEqual(b?.generation, generationB)
    }

    // MARK: reconciliation fence and wake budget

    func testWithheldBacklogMarkerLeavesIntentUnresolvedAtTheDeadline() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        let generation = machine.generation("a")
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let session = FakeTransferSession(identifier: sessionIdentifier, deliversBacklogMarker: false)
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session, reconciliationTimeout: 5)
        let manager = harness.makeManager()

        try await manager.start()
        let open = await manager.reconciliationStatus()
        XCTAssertEqual(open, .awaitingBacklog(deadline: referenceDate.addingTimeInterval(5)))

        await harness.clock.advance(by: 5)
        await eventually("deadline handled") { await manager.reconciliationStatus() != open }

        let status = await manager.reconciliationStatus()
        let submissions = await session.submissions
        let stored = await store.contents?.records.first
        XCTAssertEqual(status, .unresolved(items: [itemID("a")], reason: .deadlineExceeded))
        XCTAssertTrue(submissions.isEmpty, "a timeout is not proof of absence")
        XCTAssertEqual(stored?.generation, generation)
        XCTAssertEqual(stored?.phase, .queued)
        await assertThrows(.reconciliationUnresolved) { try await manager.flushPendingWork() }

        await session.emit(payload: .backlogDelivered)
        await eventually("late marker resolves") { await manager.reconciliationStatus() == .resolved }
        let replacements = await session.submissions
        XCTAssertEqual(replacements.map(\.generation), [generation + 1], "only now is the gone attempt replaced")
    }

    func testUnresolvedAttemptIsAdoptedWhenItsTaskIsFoundLater() async throws {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        let generation = machine.generation("a")
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let session = FakeTransferSession(identifier: sessionIdentifier, deliversBacklogMarker: false)
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session, reconciliationTimeout: 5)
        let manager = harness.makeManager()
        try await manager.start()
        await harness.clock.advance(by: 5)
        await eventually("unresolved") {
            if case .unresolved = await manager.reconciliationStatus() { return true } else { return false }
        }

        await session.addSystemTask(reference("a", generation: generation, task: 77))
        try await manager.flushPendingWork()

        let status = await manager.reconciliationStatus()
        let stored = await store.contents?.records.first
        let submissions = await session.submissions
        XCTAssertEqual(status, .resolved)
        XCTAssertEqual(stored?.binding?.taskIdentifier, 77)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testWakeHandlerIsReleasedAtTheBudgetWhenWritesFail() async throws {
        let harness = try Harness(backgroundWakeBudget: 10)
        let manager = harness.makeManager()
        let counter = CallCounter()
        _ = await MainActor.run { manager.handleBackgroundEvents(forSession: harness.sessionIdentifier) { counter.count += 1 } }
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)

        await harness.store.setFailWrites(true)
        let finished = await harness.session.emit(.finished(reference, captured: captured, bytes: 10, validators: nil))
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("wake budget armed") { await harness.clock.sleeperCount == 1 }
        let early = await MainActor.run { counter.count }
        XCTAssertEqual(early, 0)

        await harness.clock.advance(by: 10)
        await eventually("handler released at the budget") { await MainActor.run { counter.count } == 1 }
        let acknowledged = await harness.session.acknowledged ?? 0
        XCTAssertLessThan(acknowledged, finished, "uncommitted events stay with the session")

        await harness.store.setFailWrites(false)
        try await manager.flushPendingWork()
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let acknowledgedAfter = await harness.session.acknowledged
        let calls = await MainActor.run { counter.count }
        XCTAssertEqual(state, .completed(at: referenceDate.addingTimeInterval(10)))
        XCTAssertEqual(acknowledgedAfter, marker)
        XCTAssertEqual(calls, 1, "the handler is not called a second time")
    }

    func testFinaliserIsGivenTheConfiguredBudget() async throws {
        let harness = try Harness(finalizationBudget: 7)
        let manager = harness.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: harness)

        let deadline = await harness.finalizer.requests.first?.deadline
        XCTAssertEqual(deadline, referenceDate.addingTimeInterval(7))
    }

    // MARK: cleanup intent

    func testFailedDiscardIsKeptAndRetriedUntilVerified() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        let stale = path("staging/stale")
        await harness.fileSystem.putFile(harness.url(stale), size: 4)
        await harness.fileSystem.configure(failRemove: true)

        let sequence = await harness.session.emit(.finished(reference("gone", generation: 99), captured: stale, bytes: 4, validators: nil))
        await eventually("stale completion processed") { await harness.session.acknowledged == sequence }

        let queued = await harness.store.contents?.cleanupPaths
        let stillThere = await harness.fileSystem.hasFile(harness.url(stale))
        XCTAssertEqual(queued, [stale], "the failed deletion is not forgotten")
        XCTAssertTrue(stillThere)

        await harness.fileSystem.configure()
        try await manager.flushPendingWork()

        let closed = await harness.store.contents?.cleanupPaths
        let gone = await harness.fileSystem.hasFile(harness.url(stale))
        XCTAssertEqual(closed, [])
        XCTAssertFalse(gone)
    }

    func testCleanupCommittedBeforeAnInterruptionFinishesOnRestart() async throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/x"), bytes: 10, validators: nil))
        _ = machine.handle(.finalizationFailed(itemID("a"), generation: generation, .integrity), now: referenceDate, jitter: 0)
        XCTAssertTrue(machine.cleanup.contains(path("staging/x")), "committed together with the rejection")
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let harness = try Harness(store: store)
        await harness.fileSystem.putFile(harness.url(path("staging/x")), size: 10)

        try await harness.makeManager().start()

        let exists = await harness.fileSystem.hasFile(harness.url(path("staging/x")))
        let cleanup = await store.contents?.cleanupPaths
        XCTAssertFalse(exists)
        XCTAssertEqual(cleanup, [])
    }

    func testUnknownFilesAreReportedAndNeverDeleted() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: first)
        let mystery = path("staging/mystery")
        let orphan = path("media/item-77")
        await first.fileSystem.putFile(first.url(mystery), size: 3)
        await first.fileSystem.putFile(first.url(orphan), size: 3)

        let unknown = try await manager.unreferencedFiles()
        XCTAssertEqual(unknown, [orphan, mystery])

        await manager.detach()
        let restarted = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        try await restarted.start()
        let mysteryKept = await first.fileSystem.hasFile(first.url(mystery))
        let orphanKept = await first.fileSystem.hasFile(first.url(orphan))
        XCTAssertTrue(mysteryKept)
        XCTAssertTrue(orphanKept)
    }

    // MARK: completion and cancel

    func testCancelBeforeValidationKeepsTheItemCancelledUntilRetry() async throws {
        try await assertCancelDuringFinalisation(gate: .beforeRename)
    }

    func testCancelAfterRenameKeepsTheItemCancelledUntilRetry() async throws {
        try await assertCancelDuringFinalisation(gate: .afterRename)
    }

    private func assertCancelDuringFinalisation(gate: FakeFinalizer.Gate, file: StaticString = #filePath, line: UInt = #line) async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        _ = try await suspendFinalisation(harness, manager: manager, gate: gate)

        try await manager.cancel(itemID("a"))
        await harness.finalizer.release()
        await settle(manager)

        let cancelled = await manager.state(for: itemID("a"))
        let lookup = try await manager.localFile(for: itemID("a"))
        let kept = await harness.fileSystem.hasFile(harness.url(.media(generation: 1)))
        XCTAssertEqual(cancelled, .failed(DownloadFailure(kind: .cancelled)), file: file, line: line)
        XCTAssertEqual(lookup, .unavailable(.failed(DownloadFailure(kind: .cancelled))), file: file, line: line)
        XCTAssertTrue(kept, "the validated file stays with the cancelled record", file: file, line: line)

        try await manager.retry(itemID("a"))
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let submissions = await harness.session.submissions
        let generations = await harness.finalizer.requests.map(\.generation)
        XCTAssertEqual(state, .completed(at: referenceDate), file: file, line: line)
        XCTAssertEqual(submissions.count, 1, "no new transfer", file: file, line: line)
        XCTAssertEqual(generations, [1, 1], file: file, line: line)
    }

    // MARK: restart commands while an attempt is unconfirmed

    private enum RestartPair {
        case pauseThenResume
        case cancelThenRetry
    }

    /// A restored queued attempt whose binding was never written, with a session that
    /// withholds its backlog marker.
    private func unconfirmedAttempt(reconciliationTimeout: TimeInterval = 5) async throws -> (Harness, DownloadManager, UInt64) {
        let sessionIdentifier = Harness.uniqueName("session")
        var machine = DownloadStateMachine.fresh(session: sessionIdentifier)
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        let generation = machine.generation("a")
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let session = FakeTransferSession(identifier: sessionIdentifier, deliversBacklogMarker: false)
        let harness = try Harness(sessionIdentifier: sessionIdentifier, store: store, session: session, reconciliationTimeout: reconciliationTimeout)
        let manager = harness.makeManager()
        try await manager.start()
        return (harness, manager, generation)
    }

    private func send(_ pair: RestartPair, to manager: DownloadManager) async throws {
        switch pair {
        case .pauseThenResume:
            try await manager.pause(itemID("a"))
            try await manager.resume(itemID("a"))
        case .cancelThenRetry:
            try await manager.cancel(itemID("a"))
            try await manager.retry(itemID("a"))
        }
    }

    private func assertRestartKeepsTheUnconfirmedAttempt(_ pair: RestartPair, afterTimeout: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        let unresolved = ReconciliationStatus.unresolved(items: [itemID("a")], reason: .deadlineExceeded)
        if afterTimeout {
            await harness.clock.advance(by: 5)
            await eventually("deadline handled", file: file, line: line) { await manager.reconciliationStatus() == unresolved }
        }

        try await send(pair, to: manager)

        let submissions = await harness.session.submissions
        let stored = await harness.store.contents?.records.first
        XCTAssertTrue(submissions.isEmpty, "no replacement while the old attempt may still run", file: file, line: line)
        XCTAssertEqual(stored?.generation, generation, file: file, line: line)
        if afterTimeout {
            let status = await manager.reconciliationStatus()
            XCTAssertEqual(status, unresolved, file: file, line: line)
        }

        // The old attempt's completion is delivered late.
        let captured = path("staging/late")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        let sequence = await harness.session.emit(.finished(reference("a", generation: generation, task: 55), captured: captured, bytes: 10, validators: nil))
        await eventually("late completion applied", file: file, line: line) { await harness.session.acknowledged == sequence }
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let cleanup = await harness.store.contents?.cleanupPaths ?? []
        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: generation)))
        let replacements = await harness.session.submissions
        guard case .completed = state else { return XCTFail("expected completed, got \(state)", file: file, line: line) }
        XCTAssertFalse(cleanup.contains(captured), "the late capture is owned, never queued for deletion", file: file, line: line)
        XCTAssertTrue(finalExists, file: file, line: line)
        XCTAssertTrue(replacements.isEmpty, file: file, line: line)
    }

    func testPauseThenResumeKeepsTheUnconfirmedAttemptBeforeTheDeadline() async throws {
        try await assertRestartKeepsTheUnconfirmedAttempt(.pauseThenResume, afterTimeout: false)
    }

    func testPauseThenResumeKeepsTheUnconfirmedAttemptAfterTheDeadline() async throws {
        try await assertRestartKeepsTheUnconfirmedAttempt(.pauseThenResume, afterTimeout: true)
    }

    func testCancelThenRetryKeepsTheUnconfirmedAttemptBeforeTheDeadline() async throws {
        try await assertRestartKeepsTheUnconfirmedAttempt(.cancelThenRetry, afterTimeout: false)
    }

    func testCancelThenRetryKeepsTheUnconfirmedAttemptAfterTheDeadline() async throws {
        try await assertRestartKeepsTheUnconfirmedAttempt(.cancelThenRetry, afterTimeout: true)
    }

    func testDeferredResumeStartsOneAttemptOnceTheBacklogProvesTheOldOneGone() async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        try await send(.pauseThenResume, to: manager)

        await harness.session.emit(payload: .backlogDelivered)
        await eventually("marker applied") { await manager.reconciliationStatus() == .resolved }

        let submissions = await harness.session.submissions
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(submissions.map(\.generation), [generation + 1])
        XCTAssertEqual(state, .queued)
    }

    func testDeferredRetryAdoptsTheOldTaskFoundAfterTheDeadline() async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        await harness.clock.advance(by: 5)
        await eventually("unresolved") {
            if case .unresolved = await manager.reconciliationStatus() { return true } else { return false }
        }
        try await send(.cancelThenRetry, to: manager)

        await harness.session.addSystemTask(reference("a", generation: generation, task: 77))
        try await manager.flushPendingWork()

        let submissions = await harness.session.submissions
        let cancellations = await harness.session.cancellations
        let stored = await harness.store.contents?.records.first
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertEqual(stored?.binding?.taskIdentifier, 77)
        XCTAssertEqual(stored?.phase, .queued)
    }

    func testFoundTaskOfAPausedUnconfirmedAttemptIsCancelled() async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        await harness.clock.advance(by: 5)
        await eventually("unresolved") {
            if case .unresolved = await manager.reconciliationStatus() { return true } else { return false }
        }
        try await manager.pause(itemID("a"))

        await harness.session.addSystemTask(reference("a", generation: generation, task: 77))
        try await manager.flushPendingWork()

        let cancellations = await harness.session.cancellations
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(cancellations, [FakeTransferSession.Cancellation(taskIdentifier: 77, producingResumeData: true)])
        XCTAssertEqual(state, .paused(resumable: false))
    }

    // MARK: worker lifetime

    func testReleasedManagerKeepsTheRootWhileItsFinaliserRuns() async throws {
        let first = try Harness()
        var owner: DownloadManager? = first.makeManager()
        try await owner?.start()
        _ = try await suspendFinalisation(first, manager: try XCTUnwrap(owner), gate: .beforeRename)
        weak let engine = owner?.engine

        owner = nil
        for _ in 0..<2_000 where engine != nil { await Task.yield() }
        XCTAssertNotNil(engine, "the running worker keeps its engine")
        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        await assertThrows(.ownerAlreadyActive) { try await next.start() }

        await first.finalizer.release()
        await eventually("root freed once the worker returned") { (try? await next.start()) != nil }
        await settle(next)

        let state = await next.state(for: itemID("a"))
        let finalExists = await first.fileSystem.hasFile(first.url(.media(generation: 1)))
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertTrue(finalExists)
    }

    func testReleasedManagerWithAnEndedLeaseKeepsTheRootUntilItsWorkerReturns() async throws {
        let first = try Harness()
        var owner: DownloadManager? = first.makeManager()
        try await owner?.start()
        try await completeItem("a", manager: try XCTUnwrap(owner), harness: first)
        var lease: LocalFileLease?
        if case .available(let available)? = try await owner?.localFile(for: itemID("a")) { lease = available }
        XCTAssertNotNil(lease)

        // Another item's finaliser is suspended mid-way.
        try await owner?.enqueue(makeRequest("b"))
        let referenceB = try await XCTUnwrapAsync(await first.session.latestReference(for: itemID("b")))
        let captured = path("staging/b")
        await first.fileSystem.putFile(first.url(captured), size: 10)
        await first.finalizer.setGate(.beforeRename)
        await first.session.emit(.finished(referenceB, captured: captured, bytes: 10, validators: nil))
        await eventually("finaliser suspended") { await first.finalizer.suspendedCount == 1 }
        weak let engine = owner?.engine

        // Release the manager, end the last lease through a successor, drop the lease value.
        owner = nil
        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier)).makeManager()
        if let held = lease { await next.endAccess(held) }
        lease = nil
        for _ in 0..<2_000 where engine != nil { await Task.yield() }

        XCTAssertNotNil(engine, "the running worker keeps its engine")
        await assertThrows(.ownerAlreadyActive) { try await next.start() }

        await first.finalizer.release()
        await eventually("root freed once the worker returned") { (try? await next.start()) != nil }
        await settle(next)

        let stateA = await next.state(for: itemID("a"))
        let stateB = await next.state(for: itemID("b"))
        XCTAssertEqual(stateA, .completed(at: referenceDate))
        XCTAssertEqual(stateB, .completed(at: referenceDate), "the successor recovers the worker's rename")
    }

    // MARK: suspended index writes

    func testWakeHandlerIsReleasedAtTheBudgetWhileAWriteIsSuspended() async throws {
        let harness = try Harness(reconciliationTimeout: 20, backgroundWakeBudget: 10)
        let manager = harness.makeManager()
        let counter = CallCounter()
        _ = await MainActor.run { manager.handleBackgroundEvents(forSession: harness.sessionIdentifier) { counter.count += 1 } }
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)

        await harness.store.setHoldWrites(true)
        let finished = await harness.session.emit(.finished(reference, captured: captured, bytes: 10, validators: nil))
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("write suspended") { await harness.store.heldWriteCount == 1 }
        await eventually("wake budget armed while the write waits") { await harness.clock.sleeperCount == 1 }

        await harness.clock.advance(by: 10)
        await eventually("handler released at the budget") { await MainActor.run { counter.count } == 1 }
        await harness.clock.advance(by: 30)
        let held = await harness.store.heldWriteCount
        let acknowledged = await harness.session.acknowledged ?? 0
        XCTAssertEqual(held, 1, "the write is still suspended past both budgets")
        XCTAssertLessThan(acknowledged, finished, "uncommitted events stay with the session")

        await harness.store.setHoldWrites(false)
        await eventually("events applied") { await harness.session.acknowledged == marker }
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let calls = await MainActor.run { counter.count }
        guard case .completed = state else { return XCTFail("expected completed, got \(state)") }
        XCTAssertEqual(calls, 1, "the handler is not called a second time")
    }

    func testReconciliationDeadlineIsRecordedWhileAWriteIsSuspended() async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        let open = await manager.reconciliationStatus()
        XCTAssertEqual(open, .awaitingBacklog(deadline: referenceDate.addingTimeInterval(5)))

        await harness.store.setHoldWrites(true)
        let blocked = Task { try await manager.enqueue(makeRequest("b")) }
        await eventually("write suspended") { await harness.store.heldWriteCount == 1 }
        await harness.clock.advance(by: 25)

        await eventually("deadline recorded") {
            await manager.reconciliationStatus() == .unresolved(items: [itemID("a")], reason: .deadlineExceeded)
        }
        let records = await harness.store.contents?.records ?? []
        XCTAssertEqual(records.first { $0.id == itemID("a") }?.generation, generation, "nothing is concluded")

        // The outstanding writer keeps the root owned.
        let detaching = Task { await manager.detach() }
        let next = try restart(harness, session: FakeTransferSession(identifier: harness.sessionIdentifier)).makeManager()
        await assertThrows(.ownerAlreadyActive) { try await next.start() }

        await harness.store.setHoldWrites(false)
        _ = try await blocked.value
        await detaching.value
        try await next.start()

        let submissions = await harness.session.submissions
        XCTAssertFalse(submissions.contains { $0.itemID == itemID("a") }, "a timeout is not proof of absence")
    }

    // MARK: unresolved stops across a relaunch

    /// Stops the restored unconfirmed attempt, optionally asks for the restart, and ends the
    /// process. The next launch's session buffers nothing yet and withholds its marker.
    private func relaunchAfterStop(_ pair: RestartPair, restartBeforeExit: Bool) async throws -> (Harness, DownloadManager, UInt64) {
        let (first, manager, generation) = try await unconfirmedAttempt()
        switch pair {
        case .pauseThenResume:
            try await manager.pause(itemID("a"))
            if restartBeforeExit { try await manager.resume(itemID("a")) }
        case .cancelThenRetry:
            try await manager.cancel(itemID("a"))
            if restartBeforeExit { try await manager.retry(itemID("a")) }
        }
        await manager.detach()
        let next = try restart(first, session: FakeTransferSession(identifier: first.sessionIdentifier, deliversBacklogMarker: false))
        let relaunched = next.makeManager()
        try await relaunched.start()
        return (next, relaunched, generation)
    }

    private func assertBufferedCompletionSurvivesTheRelaunch(_ pair: RestartPair, restartBeforeExit: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (harness, manager, generation) = try await relaunchAfterStop(pair, restartBeforeExit: restartBeforeExit)
        if !restartBeforeExit {
            // The restart arrives early: before the backlog of the new launch was delivered.
            switch pair {
            case .pauseThenResume: try await manager.resume(itemID("a"))
            case .cancelThenRetry: try await manager.retry(itemID("a"))
            }
        }
        let early = await harness.session.submissions
        let stored = await harness.store.contents?.records.first
        XCTAssertTrue(early.isEmpty, "no replacement before the old attempt's disposition is known", file: file, line: line)
        XCTAssertEqual(stored?.generation, generation, file: file, line: line)
        XCTAssertEqual(stored?.stoppedWhileUnconfirmed, true, file: file, line: line)
        XCTAssertEqual(stored?.restartDeferred, true, file: file, line: line)

        // The old attempt's completion was buffered across the relaunch.
        let captured = path("staging/buffered")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        let sequence = await harness.session.emit(.finished(reference("a", generation: generation, task: 55), captured: captured, bytes: 10, validators: nil))
        await eventually("buffered completion applied", file: file, line: line) { await harness.session.acknowledged == sequence }
        await settle(manager)
        let marker = await harness.session.emit(payload: .backlogDelivered)
        await eventually("marker applied", file: file, line: line) { await harness.session.acknowledged == marker }

        let state = await manager.state(for: itemID("a"))
        let cleanup = await harness.store.contents?.cleanupPaths ?? []
        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: generation)))
        let submissions = await harness.session.submissions
        guard case .completed = state else { return XCTFail("expected completed, got \(state)", file: file, line: line) }
        XCTAssertFalse(cleanup.contains(captured), "the buffered capture is never queued for deletion", file: file, line: line)
        XCTAssertTrue(finalExists, file: file, line: line)
        XCTAssertTrue(submissions.isEmpty, file: file, line: line)
    }

    func testPauseExitStartThenEarlyResumeKeepsTheBufferedCompletion() async throws {
        try await assertBufferedCompletionSurvivesTheRelaunch(.pauseThenResume, restartBeforeExit: false)
    }

    func testCancelExitStartThenEarlyRetryKeepsTheBufferedCompletion() async throws {
        try await assertBufferedCompletionSurvivesTheRelaunch(.cancelThenRetry, restartBeforeExit: false)
    }

    func testDeferredResumeBeforeExitKeepsTheBufferedCompletion() async throws {
        try await assertBufferedCompletionSurvivesTheRelaunch(.pauseThenResume, restartBeforeExit: true)
    }

    func testDeferredRetryBeforeExitStartsOneAttemptOnceTheNextBacklogProvesTheOldOneGone() async throws {
        let (harness, manager, generation) = try await relaunchAfterStop(.cancelThenRetry, restartBeforeExit: true)
        let status = await manager.reconciliationStatus()
        XCTAssertEqual(status, .awaitingBacklog(deadline: referenceDate.addingTimeInterval(20)), "the restored stop is fenced")

        await harness.session.emit(payload: .backlogDelivered)
        await eventually("marker applied") { await manager.reconciliationStatus() == .resolved }

        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.map(\.generation), [generation + 1], "exactly one continuation")
        let stored = await harness.store.contents?.records.first
        XCTAssertEqual(stored?.stoppedWhileUnconfirmed, false)
        XCTAssertEqual(stored?.restartDeferred, false)
    }

    func testRestoredStopFoundAsALiveTaskIsAdoptedByTheDeferredResume() async throws {
        let (first, manager, generation) = try await unconfirmedAttempt()
        try await manager.pause(itemID("a"))
        try await manager.resume(itemID("a"))
        await manager.detach()
        let session = FakeTransferSession(identifier: first.sessionIdentifier, liveTasks: [reference("a", generation: generation, task: 61)], deliversBacklogMarker: false)
        let relaunched = try restart(first, session: session).makeManager()
        try await relaunched.start()

        let submissions = await session.submissions
        let cancellations = await session.cancellations
        let stored = await first.store.contents?.records.first
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertEqual(stored?.binding?.taskIdentifier, 61)
        XCTAssertEqual(stored?.phase, .queued)
    }

    // MARK: held policy on a stopped attempt

    func testDeferredResumeNeverAdoptsATaskUnderAnObsoletePolicy() async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        await harness.clock.advance(by: 5)
        await eventually("unresolved") {
            if case .unresolved = await manager.reconciliationStatus() { return true } else { return false }
        }
        try await manager.pause(itemID("a"))
        try await manager.setPolicy(.anyNetwork, for: itemID("a"))
        try await manager.resume(itemID("a"))

        await harness.session.addSystemTask(reference("a", generation: generation, task: 77))
        try await manager.flushPendingWork()

        let cancellations = await harness.session.cancellations
        let submissions = await harness.session.submissions
        XCTAssertEqual(cancellations, [FakeTransferSession.Cancellation(taskIdentifier: 77, producingResumeData: true)], "the old task is cancelled, not adopted")
        XCTAssertEqual(submissions.map(\.generation), [generation + 1])
        XCTAssertEqual(submissions.first?.policy, .anyNetwork)
    }

    // MARK: session storage failure

    func testUnavailableBacklogKeepsTheFenceClosedWithItsReason() async throws {
        let (harness, manager, generation) = try await unconfirmedAttempt()
        await harness.session.emit(payload: .backlogUnavailable)
        let unresolved = ReconciliationStatus.unresolved(items: [itemID("a")], reason: .sessionStorageFailed)
        await eventually("reported") { await manager.reconciliationStatus() == unresolved }

        await assertThrows(.reconciliationUnresolved) { try await manager.flushPendingWork() }
        await harness.clock.advance(by: 30)
        let later = await manager.reconciliationStatus()
        let early = await harness.session.submissions
        XCTAssertEqual(later, unresolved, "the deadline does not hide the reason")
        XCTAssertTrue(early.isEmpty, "an incomplete backlog proves nothing")

        await harness.session.emit(payload: .backlogDelivered)
        await eventually("marker applied") { await manager.reconciliationStatus() == .resolved }
        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.map(\.generation), [generation + 1])
    }

    // MARK: leases on replaced files

    func testReplacedFileIsKeptUntilItsLeaseEnds() async throws {
        let harness = try Harness()
        let manager = harness.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: harness)
        let old = RelativePath.media(generation: 1)
        guard case .available(let lease) = try await manager.localFile(for: itemID("a")) else { return XCTFail("no lease") }

        // The file changes size behind the package's back: corrupt, retried, replaced.
        await harness.fileSystem.putFile(harness.url(old), size: 99)
        let corrupt = try await manager.localFile(for: itemID("a"))
        XCTAssertEqual(corrupt, .unavailable(.corrupt))
        try await manager.retry(itemID("a"))
        let latest = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a-\(latest.generation)")
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        await manager.engine.ingest(.transfer(.finished(latest, captured: captured, bytes: 10, validators: nil)))
        await settle(manager)

        let state = await manager.state(for: itemID("a"))
        let keptWhileLeased = await harness.fileSystem.hasFile(harness.url(old))
        let intent = await harness.store.contents?.cleanupPaths ?? []
        XCTAssertEqual(state, .completed(at: referenceDate))
        XCTAssertTrue(keptWhileLeased, "the lease URL stays valid until the lease ends")
        XCTAssertTrue(intent.contains(old), "the deletion intent stays persisted")

        await manager.endAccess(lease)
        let deleted = await harness.fileSystem.hasFile(harness.url(old))
        let closed = await harness.store.contents?.cleanupPaths ?? []
        XCTAssertFalse(deleted)
        XCTAssertFalse(closed.contains(old))
    }
}
