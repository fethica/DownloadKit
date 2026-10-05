//
//  RelaunchSequencingTests.swift
//  DownloadKitTests
//
//  The background-wake handler across a relaunch: forwarded before the manager exists, before
//  or after start, twice, for another identifier, with the wake's events buffered before start,
//  and with the drained marker before or after the wake budget. Every handler runs exactly once,
//  on the main thread.
//

import Foundation
import XCTest
@testable import DownloadKit

/// Counts calls and records whether every call ran on the main thread.
@MainActor
final class WakeHandlerProbe {
    private(set) var calls = 0
    private(set) var offMainCalls = 0

    nonisolated init() {}

    func handler() -> () -> Void {
        { [self] in
            MainActor.assumeIsolated {
                self.calls += 1
                if !Thread.isMainThread { self.offMainCalls += 1 }
            }
        }
    }
}

final class RelaunchSequencingTests: XCTestCase {
    /// The deadline of a handler accepted before the clock moved, with a 10 second budget.
    private static let deadline = referenceDate.addingTimeInterval(10)

    /// A relaunch: a fresh harness over the first one's storage, with a session that holds a
    /// completion for the attempt the first launch started.
    private func relaunchWithBufferedCompletion(backgroundWakeBudget: TimeInterval = 20, liveTaskIdentifier: Int? = nil) async throws -> (harness: Harness, captured: RelativePath, reference: TransferTaskReference) {
        let first = try Harness(backgroundWakeBudget: backgroundWakeBudget)
        let manager = first.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await first.session.latestReference(for: itemID("a")))
        await manager.detach()

        let captured = path("staging/woken")
        await first.fileSystem.putFile(first.url(captured), size: 10)
        let live = liveTaskIdentifier.map { [TransferTaskReference(itemID: reference.itemID, generation: reference.generation, taskIdentifier: $0)] } ?? []
        let session = FakeTransferSession(identifier: first.sessionIdentifier, liveTasks: live, backlog: [.finished(reference, captured: captured, bytes: 10, validators: nil)])
        let second = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store, session: session, clock: first.clock, backgroundWakeBudget: backgroundWakeBudget)
        return (second, captured, reference)
    }

    func testHandlerForwardedBeforeTheManagerExistsRunsOnceAfterTheWakeIsCommitted() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion()
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        // The system's callback comes first; no manager exists yet.
        let accepted = await MainActor.run { relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        XCTAssertTrue(accepted)
        // The wake's events are already buffered in the session when the manager starts.
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)

        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()

        await eventually("handler called") { await MainActor.run { probe.calls } == 1 }
        let record = await harness.store.contents?.records.first
        let acknowledged = await harness.session.acknowledged
        XCTAssertNotEqual(record?.journal, .notStarted, "the buffered completion was committed before the handler ran")
        XCTAssertEqual(acknowledged, marker)
        let offMain = await MainActor.run { probe.offMainCalls }
        let pending = await MainActor.run { relay.pendingHandlerCount(forSession: harness.sessionIdentifier) }
        XCTAssertEqual(offMain, 0, "called on the main thread")
        XCTAssertEqual(pending, 0)
        withExtendedLifetime(manager) {}
    }

    func testHandlerForwardedAfterInitBeforeStartRunsOnce() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion()
        let relay = harness.makeRelay()
        let manager = harness.makeManager(backgroundEvents: relay)
        let probe = WakeHandlerProbe()
        let accepted = await MainActor.run { manager.handleBackgroundEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        XCTAssertTrue(accepted)
        let shared = await MainActor.run { relay.pendingHandlerCount(forSession: harness.sessionIdentifier) }
        XCTAssertEqual(shared, 1, "the manager and the relay hold the same handlers")

        try await manager.start()
        let early = await MainActor.run { probe.calls }
        XCTAssertEqual(early, 0, "no marker yet")
        await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("handler called") { await MainActor.run { probe.calls } == 1 }
    }

    func testDuplicateForwardsAndDuplicateMarkersCallEachHandlerOnce() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion()
        let relay = harness.makeRelay()
        let first = WakeHandlerProbe()
        let second = WakeHandlerProbe()
        await MainActor.run {
            relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: first.handler())
            relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: second.handler())
        }
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        await harness.session.emit(payload: .backgroundEventsFinished)
        let duplicate = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("both markers applied") { await harness.session.acknowledged == duplicate }

        let calls = await MainActor.run { (first.calls, second.calls) }
        XCTAssertEqual(calls.0, 1)
        XCTAssertEqual(calls.1, 1)
        withExtendedLifetime(manager) {}
    }

    func testUnrelatedIdentifierIsRefusedAndNeverCalled() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion()
        let relay = harness.makeRelay()
        let unrelated = WakeHandlerProbe()
        let refused = await MainActor.run { relay.handleEvents(forSession: "another.app.session", completionHandler: unrelated.handler()) }
        XCTAssertFalse(refused, "the host stays responsible for another identifier")
        let manager = harness.makeManager(backgroundEvents: relay)
        let refusedByManager = await MainActor.run { manager.handleBackgroundEvents(forSession: "another.app.session", completionHandler: unrelated.handler()) }
        XCTAssertFalse(refusedByManager)

        try await manager.start()
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("marker applied") { await harness.session.acknowledged == marker }
        let calls = await MainActor.run { unrelated.calls }
        let held = await MainActor.run { relay.pendingHandlerCount(forSession: "another.app.session") }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(held, 0)
    }

    func testMarkerBeforeTheBudgetCallsOnceAndTheBudgetAddsNothing() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }

        await harness.clock.advance(by: 4)
        await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("handler called at the marker") { await MainActor.run { probe.calls } == 1 }
        await eventually("deadline disarmed") { await !harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 30)
        await Task.yield()
        let calls = await MainActor.run { probe.calls }
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(manager) {}
    }

    func testMarkerThatNeverComesReleasesTheHandlerAtTheBudgetAndALateMarkerAddsNothing() async throws {
        let (harness, _, reference) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        let early = await MainActor.run { probe.calls }
        XCTAssertEqual(early, 0)

        // The system's drained callback does not come within the budget.
        await harness.clock.advance(by: 10)
        await eventually("handler released at the budget") { await MainActor.run { probe.calls } == 1 }

        let late = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("late marker applied") { await harness.session.acknowledged == late }
        let calls = await MainActor.run { probe.calls }
        XCTAssertEqual(calls, 1, "the late marker calls nothing")
        let state = await manager.snapshot(for: reference.itemID)
        XCTAssertNotNil(state)
    }

    func testHandlerArrivingAfterItsMarkerWasAppliedIsReleasedByTheBudget() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("marker applied") { await harness.session.acknowledged == marker }

        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        // Waits for this handler's own timer: the reconciliation timer (another deadline) is
        // also a sleeper, so a count of sleepers could be satisfied before this one exists.
        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("handler released") { await MainActor.run { probe.calls } == 1 }
    }

    func testMarkerStuckBehindAnUncommittedEventReleasesAtTheBudgetThenAppliesInOrder() async throws {
        let (harness, _, reference) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await harness.store.setFailWrites(true)
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()

        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("handler released at the budget") { await MainActor.run { probe.calls } == 1 }
        let acknowledged = await harness.session.acknowledged ?? 0
        XCTAssertLessThan(acknowledged, marker, "the uncommitted completion stays with the session")

        await harness.store.setFailWrites(false)
        try? await manager.flushPendingWork()
        await eventually("marker applied after the completion") { await harness.session.acknowledged == marker }
        await settle(manager)
        let calls = await MainActor.run { probe.calls }
        let available = await manager.snapshot(for: reference.itemID)?.isAvailableOffline
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(available, true)
    }

    // MARK: Deadlines without a running manager

    func testHandlerWithoutAnyManagerIsCalledAtItsDeadline() async throws {
        let harness = try Harness(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }

        await harness.clock.advance(by: 9)
        let early = await MainActor.run { probe.calls }
        XCTAssertEqual(early, 0)
        await harness.clock.advance(by: 1)
        await eventually("called at the deadline") { await MainActor.run { probe.calls } == 1 }
        let pending = await MainActor.run { relay.pendingHandlerCount(forSession: harness.sessionIdentifier) }
        let offMain = await MainActor.run { probe.offMainCalls }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(offMain, 0)
    }

    func testHandlerIsCalledAtItsDeadlineWhenStartRefusesAnUnsupportedIndex() async throws {
        let store = InMemoryIndexStore(contents: IndexContents(schemaVersion: 999, nextGeneration: 7))
        let before = await store.rawData
        let harness = try Harness(store: store, backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        let manager = harness.makeManager(backgroundEvents: relay)
        do {
            try await manager.start()
            XCTFail("an unsupported index must be refused")
        } catch {}

        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("called at the deadline") { await MainActor.run { probe.calls } == 1 }
        let after = await store.rawData
        XCTAssertEqual(before, after, "the refused index is untouched")
    }

    func testHandlerIsCalledAtItsDeadlineWhenProtectedStorageFailsTheStart() async throws {
        let harness = try Harness(backgroundWakeBudget: 10)
        let manager = harness.makeManager()
        let probe = WakeHandlerProbe()
        // A manager without a receiver keeps its own handlers, with the configuration's budget.
        await MainActor.run { _ = manager.handleBackgroundEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await harness.fileSystem.configure(failApplicationSupport: true)
        do {
            try await manager.start()
            XCTFail("unavailable storage must fail the start")
        } catch {}

        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("called at the deadline") { await MainActor.run { probe.calls } == 1 }
    }

    func testHandlerIsCalledAtItsDeadlineWhileReconciliationIsBlocked() async throws {
        // The system lists the attempt under another task number: reconciliation writes the
        // binding, and that write does not return.
        let (harness, _, reference) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10, liveTaskIdentifier: 9_999)
        let relay = harness.makeRelay()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await harness.store.setHoldWrites(true)
        let manager = harness.makeManager(backgroundEvents: relay)
        let starting = Task { try await manager.start() }
        await eventually("reconciliation suspended on the index") { await harness.store.heldWriteCount == 1 }

        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("called while start is still suspended") { await MainActor.run { probe.calls } == 1 }
        let held = await harness.store.heldWriteCount
        XCTAssertEqual(held, 1)

        await harness.store.setHoldWrites(false)
        try await starting.value
        let record = await harness.store.contents?.records.first { $0.id == reference.itemID }
        XCTAssertEqual(record?.generation, reference.generation, "nothing was lost to the deadline")
        let calls = await MainActor.run { probe.calls }
        XCTAssertEqual(calls, 1)
    }

    func testHandlerPendingAtDetachIsCalledOnceAtItsDeadline() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await manager.detach()

        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("called after detach") { await MainActor.run { probe.calls } == 1 }

        // A marker the detached manager can no longer apply, and more time, add nothing.
        await harness.session.emit(payload: .backgroundEventsFinished)
        await harness.clock.advance(by: 30)
        await Task.yield()
        let calls = await MainActor.run { probe.calls }
        let pending = await MainActor.run { relay.pendingHandlerCount(forSession: harness.sessionIdentifier) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pending, 0)
    }

    // MARK: Two wakes

    func testALateMarkerOfAnExpiredWakeNeverReleasesTheNextWake() async throws {
        let harness = try Harness(backgroundWakeBudget: 10)
        let relay = harness.makeRelay()
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        try await manager.enqueue(makeRequest("b"))
        let first = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let second = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("b")))
        await harness.fileSystem.putFile(harness.url(path("staging/a")), size: 10)
        await harness.fileSystem.putFile(harness.url(path("staging/b")), size: 10)

        // Wake A: its marker is held in the manager behind an event the index cannot take.
        let wakeA = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: wakeA.handler()) }
        await harness.store.setFailWrites(true)
        await harness.session.emit(.finished(first, captured: path("staging/a"), bytes: 10, validators: nil))
        let markerA = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("the handler's deadline armed") { await harness.clock.hasSleeper(until: Self.deadline) }
        await harness.clock.advance(by: 10)
        await eventually("wake A released at its deadline") { await MainActor.run { wakeA.calls } == 1 }

        // Wake B: its handler arrives, then its event, still uncommitted when A's marker applies.
        let wakeB = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: wakeB.handler()) }
        let eventB = await harness.session.emit(.finished(second, captured: path("staging/b"), bytes: 10, validators: nil))
        XCTAssertGreaterThan(eventB, markerA)

        await harness.store.setFailWrites(false)
        try? await manager.flushPendingWork()
        await eventually("A's marker and B's event applied") { await (harness.session.acknowledged ?? 0) >= eventB }
        await settle(manager)
        let early = await MainActor.run { (wakeA.calls, wakeB.calls, relay.pendingHandlerCount(forSession: harness.sessionIdentifier)) }
        XCTAssertEqual(early.0, 1)
        XCTAssertEqual(early.1, 0, "A's late marker does not answer wake B")
        XCTAssertEqual(early.2, 1)

        // B's own marker answers it.
        await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("wake B released by its own marker") { await MainActor.run { wakeB.calls } == 1 }
        let calls = await MainActor.run { (wakeA.calls, wakeB.calls) }
        XCTAssertEqual(calls.0, 1)
        XCTAssertEqual(calls.1, 1)
        withExtendedLifetime(manager) {}
    }
}
