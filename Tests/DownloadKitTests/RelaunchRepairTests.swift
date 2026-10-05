//
//  RelaunchRepairTests.swift
//  DownloadKitTests
//
//  Task and index repair on a relaunch, one interruption window each: a binding whose task is
//  gone, a task without an index row (the package's own, and one naming another session), a
//  capture without its journal, a journal without its capture, and a completed row without its
//  file.
//

import Foundation
import XCTest
@testable import DownloadKit

final class RelaunchRepairTests: XCTestCase {

    private func contents(of machine: DownloadStateMachine) -> IndexContents {
        IndexContents(nextGeneration: machine.nextGeneration, records: Array(machine.records.values))
    }

    /// An index holding one attempt of "a" bound to task 7, as a previous launch left it.
    private func boundAttempt() throws -> (store: InMemoryIndexStore, generation: UInt64) {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a", task: 7)
        return (InMemoryIndexStore(contents: contents(of: machine)), generation)
    }

    func testStaleBindingWhoseTaskIsGoneIsReplacedOnceAfterTheBacklog() async throws {
        let (store, generation) = try boundAttempt()
        let identifier = Harness.uniqueName("session")
        let session = FakeTransferSession(identifier: identifier, deliversBacklogMarker: false)
        let harness = try Harness(sessionIdentifier: identifier, store: store, session: session)
        let manager = harness.makeManager()
        try await manager.start()

        let beforeMarker = await session.submissions
        XCTAssertTrue(beforeMarker.isEmpty, "absence is not proof before the backlog marker")
        await session.emit(payload: .backlogDelivered)
        await eventually("replacement submitted") { await session.submissions.count == 1 }
        await eventually("replacement bound") { await store.contents?.records.first?.binding?.taskIdentifier == 101 }
        let submissions = await session.submissions
        let stored = await store.contents?.records.first
        XCTAssertGreaterThan(submissions[0].generation, generation, "a new attempt, not the stale one")
        XCTAssertEqual(stored?.binding?.taskIdentifier, 101, "the stale binding was replaced")
        let status = await manager.reconciliationStatus()
        XCTAssertEqual(status, .resolved)
    }

    func testOwnTaskWithoutAnIndexRowIsCancelledAndAnotherSessionsTaskIsUntouched() async throws {
        let (store, generation) = try boundAttempt()
        let identifier = Harness.uniqueName("session")
        // The package's own description for an item the index no longer holds.
        let ownStale = SystemTransferTask(taskIdentifier: 30, taskDescription: TransferTaskReference.taskDescription(itemID: itemID("gone"), generation: 2, sessionIdentifier: identifier))
        // A task naming another session, even for the very attempt the index waits for.
        let otherSession = SystemTransferTask(taskIdentifier: 31, taskDescription: TransferTaskReference.taskDescription(itemID: itemID("a"), generation: generation, sessionIdentifier: "another.session"))
        let unmapped = SystemTransferTask(taskIdentifier: 32, taskDescription: "host-owned task")
        let session = FakeTransferSession(identifier: identifier, unmappedTasks: [ownStale, otherSession, unmapped])
        let harness = try Harness(sessionIdentifier: identifier, store: store, session: session)
        let manager = harness.makeManager()
        try await manager.start()

        await eventually("the waiting attempt is replaced, not adopted from the other session") { await session.submissions.count == 1 }
        let cancellations = await session.cancellations
        let stored = await store.contents?.records.first
        XCTAssertEqual(cancellations, [.init(taskIdentifier: 30, producingResumeData: false)], "only the package's own stale task is cancelled")
        XCTAssertNotEqual(stored?.binding?.taskIdentifier, 31, "a task of another session is never adopted")
        XCTAssertNil(otherSession.reference(inSession: identifier))
        XCTAssertNotNil(otherSession.reference, "the session-blind parse still reads it")
    }

    func testCaptureWithoutItsJournalIsAdoptedFromTheReplayAndAnUnclaimedOneIsOnlyInventoried() async throws {
        let (store, generation) = try boundAttempt()
        let identifier = Harness.uniqueName("session")
        // Moved into staging inside the callback; the index never recorded it.
        let captured = path("staging/captured-before-commit")
        let unclaimed = path("staging/no-event-survived")
        let session = FakeTransferSession(identifier: identifier, backlog: [.finished(reference("a", generation: generation, task: 7), captured: captured, bytes: 10, validators: nil)])
        let harness = try Harness(sessionIdentifier: identifier, store: store, session: session)
        await harness.fileSystem.putFile(harness.url(captured), size: 10)
        await harness.fileSystem.putFile(harness.url(unclaimed), size: 3)
        let manager = harness.makeManager()
        try await manager.start()

        await eventually("captured file completed") { await manager.snapshot(for: itemID("a"))?.isAvailableOffline == true }
        let submissions = await session.submissions
        let unknown = try await manager.unreferencedFiles()
        let stillThere = await harness.fileSystem.hasFile(harness.url(unclaimed))
        XCTAssertTrue(submissions.isEmpty, "no replacement over a captured completion")
        XCTAssertEqual(unknown, [unclaimed], "an unclaimed capture is reported")
        XCTAssertTrue(stillThere, "and never deleted")
    }

    func testJournalWithoutItsCaptureFailsWithoutPublishingACompletion() async throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a", task: 7)
        _ = machine.send(.finished(reference("a", generation: generation, task: 7), captured: path("staging/lost"), bytes: 10, validators: nil))
        XCTAssertEqual(machine.record("a")?.journal, .captured)
        let store = InMemoryIndexStore(contents: contents(of: machine))
        let harness = try Harness(store: store)
        let manager = harness.makeManager()
        try await manager.start()
        await settle(manager)

        await eventually("the lost capture is rejected") { await manager.state(for: itemID("a")) == .failed(DownloadFailure(kind: .storage)) }
        let lookup = try await manager.localFile(for: itemID("a"))
        let submissions = await harness.session.submissions
        XCTAssertEqual(lookup, .unavailable(.failed(DownloadFailure(kind: .storage))))
        XCTAssertTrue(submissions.isEmpty, "nothing is fetched again without a retry")
    }

    func testCompletedRowWithoutItsFileBecomesMissing() async throws {
        let first = try Harness()
        let manager = first.makeManager()
        try await manager.start()
        try await completeItem("a", manager: manager, harness: first)
        await manager.detach()
        try await first.fileSystem.removeItem(at: first.url(.media(generation: 1)))

        let restarted = try Harness(namespace: first.namespace, sessionIdentifier: first.sessionIdentifier, fileSystem: first.fileSystem, store: first.store).makeManager()
        try await restarted.start()

        let state = await restarted.state(for: itemID("a"))
        let lookup = try await restarted.localFile(for: itemID("a"))
        XCTAssertEqual(state, .missing)
        XCTAssertEqual(lookup, .unavailable(.missing))
    }
}
