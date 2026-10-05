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

    /// A relaunch: a fresh harness over the first one's storage, with a session that holds a
    /// completion for the attempt the first launch started.
    private func relaunchWithBufferedCompletion(backgroundWakeBudget: TimeInterval = 20) async throws -> (harness: Harness, captured: RelativePath, reference: TransferTaskReference) {
        let first = try Harness(backgroundWakeBudget: backgroundWakeBudget)
        let manager = first.makeManager()
        try await manager.start()
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await first.session.latestReference(for: itemID("a")))
        await manager.detach()

        let captured = path("staging/woken")
        await first.fileSystem.putFile(first.url(captured), size: 10)
        let session = FakeTransferSession(identifier: first.sessionIdentifier, backlog: [.finished(reference, captured: captured, bytes: 10, validators: nil)])
        let second = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store, session: session, clock: first.clock, backgroundWakeBudget: backgroundWakeBudget)
        return (second, captured, reference)
    }

    func testHandlerForwardedBeforeTheManagerExistsRunsOnceAfterTheWakeIsCommitted() async throws {
        let (harness, _, _) = try await relaunchWithBufferedCompletion()
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
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
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
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
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
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
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
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
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        await eventually("budget armed for the waiting handler") { await harness.clock.sleeperCount == 1 }

        await harness.clock.advance(by: 4)
        await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("handler called at the marker") { await MainActor.run { probe.calls } == 1 }
        await eventually("budget disarmed") { await harness.clock.sleeperCount == 0 }
        await harness.clock.advance(by: 30)
        await Task.yield()
        let calls = await MainActor.run { probe.calls }
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(manager) {}
    }

    func testMarkerThatNeverComesReleasesTheHandlerAtTheBudgetAndALateMarkerAddsNothing() async throws {
        let (harness, _, reference) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        await eventually("budget armed") { await harness.clock.sleeperCount == 1 }
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
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        await eventually("marker applied") { await harness.session.acknowledged == marker }

        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await eventually("budget armed by the handler") { await harness.clock.sleeperCount == 1 }
        await harness.clock.advance(by: 10)
        await eventually("handler released") { await MainActor.run { probe.calls } == 1 }
    }

    func testMarkerStuckBehindAnUncommittedEventReleasesAtTheBudgetThenAppliesInOrder() async throws {
        let (harness, _, reference) = try await relaunchWithBufferedCompletion(backgroundWakeBudget: 10)
        let relay = BackgroundTransferEvents(sessionIdentifiers: [harness.sessionIdentifier])
        let probe = WakeHandlerProbe()
        await MainActor.run { _ = relay.handleEvents(forSession: harness.sessionIdentifier, completionHandler: probe.handler()) }
        await harness.store.setFailWrites(true)
        let marker = await harness.session.emit(payload: .backgroundEventsFinished)
        let manager = harness.makeManager(backgroundEvents: relay)
        try await manager.start()

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
}
