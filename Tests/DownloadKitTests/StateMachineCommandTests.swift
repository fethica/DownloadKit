//
//  StateMachineCommandTests.swift
//  DownloadKitTests
//
//  One test per row of the command transition table.
//

import XCTest
@testable import DownloadKit

final class StateMachineCommandTests: XCTestCase {

    // MARK: enqueue

    func testEnqueueNewItemQueuesAndSubmitsWithFirstGeneration() throws {
        var machine = DownloadStateMachine.fresh()
        let outcome = try machine.handle(.enqueue(makeRequest("a", expectedLength: 100)), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(machine.generation("a"), 1)
        XCTAssertEqual(outcome.submissions.count, 1)
        XCTAssertEqual(outcome.submissions.first?.generation, 1)
        XCTAssertEqual(outcome.submissions.first?.policy, .unmeteredOnly)
        XCTAssertEqual(outcome.submissions.first?.expectedLength, 100)
        XCTAssertEqual(outcome.changed, [itemID("a")])
    }

    func testDuplicateEnqueueIsIdempotent() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        let before = machine

        let outcome = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate.addingTimeInterval(5))

        XCTAssertEqual(outcome, DownloadStateMachine.Outcome())
        XCTAssertEqual(machine, before)
    }

    func testDuplicateEnqueueOfCompletedItemDoesNotResubmit() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/x"), bytes: 10, validators: nil))
        _ = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)

        let outcome = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)

        XCTAssertTrue(outcome.effects.isEmpty)
        XCTAssertEqual(machine.phase("a"), .completed(at: referenceDate))
    }

    func testEnqueueWithNewURLSameRevisionUpdatesSourceWithoutResubmitting() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")

        let outcome = try machine.handle(.enqueue(makeRequest("a", url: "https://cdn.example.com/signed/one.m4a")), now: referenceDate)

        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertEqual(machine.record("a")?.request.sourceURL.host, "cdn.example.com")
        XCTAssertEqual(machine.generation("a"), 1)
    }

    func testEnqueueWithDifferentRevisionIsAConflictAndChangesNothing() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        let before = machine

        XCTAssertThrowsError(try machine.handle(.enqueue(makeRequest("a", revision: "r2")), now: referenceDate)) { error in
            XCTAssertEqual(error as? DownloadError, .conflictingRequest(itemID("a")))
        }
        XCTAssertEqual(machine, before)
    }

    func testEnqueueWithDifferentExpectedLengthIsAConflict() throws {
        var machine = DownloadStateMachine.fresh()
        _ = try machine.handle(.enqueue(makeRequest("a", expectedLength: 10)), now: referenceDate)

        XCTAssertThrowsError(try machine.handle(.enqueue(makeRequest("a", expectedLength: 11)), now: referenceDate)) { error in
            XCTAssertEqual(error as? DownloadError, .conflictingRequest(itemID("a")))
        }
    }

    func testEnqueueWhileRemovingIsRejected() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)

        XCTAssertThrowsError(try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)) { error in
            XCTAssertEqual(error as? DownloadError, .itemBeingRemoved(itemID("a")))
        }
    }

    func testEnqueueOfMissingItemDownloadsAgain() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try completed(&machine, "a")
        _ = machine.handle(.fileMissing(itemID("a"), generation: generation), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .missing)

        let outcome = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(outcome.submissions.count, 1)
        XCTAssertGreaterThan(machine.generation("a"), generation)
    }

    func testEnqueueRejectsNonHTTPURLs() {
        var machine = DownloadStateMachine.fresh()
        XCTAssertThrowsError(try machine.handle(.enqueue(makeRequest("a", url: "ftp://example.com/x")), now: referenceDate)) { error in
            XCTAssertEqual(error as? DownloadError, .unsupportedURL(itemID("a")))
        }
        XCTAssertTrue(machine.records.isEmpty)
    }

    func testEnqueueStartsWaitingWhenKnownPathIsDisallowed() throws {
        var machine = DownloadStateMachine.fresh()
        _ = machine.handle(.pathChanged(NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true)), now: referenceDate, jitter: 0)

        let outcome = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .waiting(.networkPolicy))
        XCTAssertEqual(outcome.submissions.count, 1, "the system holds the task until the policy allows it")
    }

    // MARK: pause

    func testPauseActiveItemCancelsProducingResumeData() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a", task: 42)

        let outcome = try machine.handle(.pause(itemID("a")), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .paused)
        XCTAssertEqual(outcome.effects, [.cancelTask(itemID("a"), taskIdentifier: 42, producingResumeData: true)])
        XCTAssertNil(machine.record("a")?.binding)
    }

    func testPauseScheduledRetryUnschedulesIt() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .network(code: -1001)))

        let outcome = try machine.handle(.pause(itemID("a")), now: referenceDate)

        XCTAssertEqual(outcome.effects, [.unscheduleRetry(itemID("a"))])
        XCTAssertEqual(machine.phase("a"), .paused)
        XCTAssertNil(machine.record("a")?.retryAt)
    }

    func testPauseIsIdempotentAndIgnoredForSettledItems() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        XCTAssertTrue(try machine.handle(.pause(itemID("a")), now: referenceDate).effects.isEmpty)

        _ = try completed(&machine, "b")
        XCTAssertFalse(try machine.handle(.pause(itemID("b")), now: referenceDate).hasStateChanges)
    }

    func testCommandsOnUnknownItemsThrow() {
        var machine = DownloadStateMachine.fresh()
        for command in [DownloadStateMachine.Command.pause(itemID("x")), .resume(itemID("x")), .cancel(itemID("x")), .retry(itemID("x"))] {
            XCTAssertThrowsError(try machine.handle(command, now: referenceDate)) { error in
                XCTAssertEqual(error as? DownloadError, .unknownItem(itemID("x")))
            }
        }
    }

    // MARK: resume

    func testResumeSubmitsNewGenerationWithCapturedResumeData() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        _ = machine.send(.resumeDataCaptured(reference("a", generation: generation), path("staging/resume-a")))
        XCTAssertEqual(machine.record("a")?.snapshot.state, .paused(resumable: true))

        let outcome = try machine.handle(.resume(itemID("a")), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(outcome.submissions.first?.resumeDataPath, path("staging/resume-a"))
        XCTAssertEqual(outcome.submissions.first?.generation, machine.generation("a"))
        XCTAssertGreaterThan(machine.generation("a"), generation)
        XCTAssertNil(machine.record("a")?.resumeDataPath, "the session owns the resume data after submission")
    }

    func testResumeOfNonPausedItemIsANoOp() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        XCTAssertTrue(try machine.handle(.resume(itemID("a")), now: referenceDate).effects.isEmpty)
    }

    // MARK: cancel

    func testCancelEndsIntentKeepsRecordAndStopsRetries() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a", task: 9)

        let outcome = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
        XCTAssertEqual(outcome.effects, [.cancelTask(itemID("a"), taskIdentifier: 9, producingResumeData: true)])
        XCTAssertNotNil(machine.record("a"))
    }

    func testCancelOfScheduledRetryUnschedules() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .network(code: nil)))

        let outcome = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        XCTAssertEqual(outcome.effects, [.unscheduleRetry(itemID("a"))])
        XCTAssertNil(machine.record("a")?.retryAt)
    }

    func testCancelOfCompletedItemDoesNothing() throws {
        var machine = DownloadStateMachine.fresh()
        try completed(&machine, "a")
        let outcome = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        XCTAssertFalse(outcome.hasStateChanges)
        XCTAssertTrue(outcome.effects.isEmpty)
    }

    // MARK: retry

    func testRetryOfFailedItemStartsNewAttemptAndResetsCount() throws {
        var machine = DownloadStateMachine.fresh(retry: RetryPolicy(maximumAutomaticRetries: 0))
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .http(status: 404, retryAfter: nil)))
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .http, httpStatus: 404)))

        let outcome = try machine.handle(.retry(itemID("a")), now: referenceDate)

        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(machine.record("a")?.automaticRetryCount, 0)
        XCTAssertEqual(outcome.submissions.count, 1)
        XCTAssertGreaterThan(machine.generation("a"), generation)
    }

    func testRetryOfScheduledRetryRunsNow() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .network(code: nil)))

        let outcome = try machine.handle(.retry(itemID("a")), now: referenceDate)

        XCTAssertEqual(outcome.effects.first, .unscheduleRetry(itemID("a")))
        XCTAssertEqual(outcome.submissions.count, 1)
        XCTAssertEqual(machine.record("a")?.automaticRetryCount, 0)
    }

    func testRetryIsIgnoredForActiveAndCompletedItems() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        try completed(&machine, "b")
        XCTAssertTrue(try machine.handle(.retry(itemID("a")), now: referenceDate).effects.isEmpty)
        XCTAssertTrue(try machine.handle(.retry(itemID("b")), now: referenceDate).effects.isEmpty)
    }

    // MARK: remove

    func testRemoveActiveItemTombstonesWithNewGenerationAndDeletesOwnedFiles() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a", task: 5)

        let outcome = try machine.handle(.remove(itemID("a")), now: referenceDate)

        let tombstone = machine.generation("a")
        XCTAssertEqual(machine.phase("a"), .removing)
        XCTAssertGreaterThan(tombstone, generation)
        XCTAssertEqual(outcome.effects, [
            .cancelTask(itemID("a"), taskIdentifier: 5, producingResumeData: false),
            .deleteOwnedFiles(itemID("a"), generation: tombstone, paths: []),
        ])
    }

    func testRemoveCompletedItemListsOnlyItsOwnFiles() throws {
        var machine = DownloadStateMachine.fresh()
        let generationA = try completed(&machine, "a")
        try completed(&machine, "b")

        let outcome = try machine.handle(.remove(itemID("a")), now: referenceDate)

        XCTAssertEqual(outcome.effects, [.deleteOwnedFiles(itemID("a"), generation: machine.generation("a"), paths: [.media(generation: generationA)])])
        XCTAssertNotEqual(machine.phase("b"), .removing)
    }

    func testRemoveOfUnknownOrRemovingItemIsANoOp() throws {
        var machine = DownloadStateMachine.fresh()
        XCTAssertEqual(try machine.handle(.remove(itemID("x")), now: referenceDate), DownloadStateMachine.Outcome())

        try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)
        XCTAssertEqual(try machine.handle(.remove(itemID("a")), now: referenceDate), DownloadStateMachine.Outcome())
    }

    func testRemovalFinishedDeletesTheRecord() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)

        let outcome = machine.handle(.removalFinished(itemID("a"), generation: machine.generation("a")), now: referenceDate, jitter: 0)

        XCTAssertNil(machine.record("a"))
        XCTAssertEqual(outcome.deleted, [itemID("a")])
        XCTAssertTrue(outcome.changed.isEmpty)
    }

    // MARK: policy

    func testSetDefaultPolicyToSameValueIsANoOp() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        XCTAssertEqual(try machine.handle(.setDefaultPolicy(.unmeteredOnly), now: referenceDate), DownloadStateMachine.Outcome())
    }

    func testSetDefaultPolicyResubmitsEachAffectedTransferExactlyOnce() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a", task: 1)
        try machine.enqueueAndBind("b", task: 2)
        try machine.enqueueAndBind("c", task: 3, request: makeRequest("c", policy: .anyNetwork))
        try machine.enqueueAndBind("d", task: 4)
        _ = try machine.handle(.pause(itemID("d")), now: referenceDate)

        let outcome = try machine.handle(.setDefaultPolicy(.anyNetwork), now: referenceDate)

        XCTAssertTrue(outcome.globalsChanged)
        XCTAssertEqual(outcome.submissions.map(\.itemID), [itemID("a"), itemID("b")])
        XCTAssertTrue(outcome.submissions.allSatisfy { $0.policy == .anyNetwork })
        XCTAssertEqual(outcome.cancellations, [
            .cancelTask(itemID("a"), taskIdentifier: 1, producingResumeData: true),
            .cancelTask(itemID("b"), taskIdentifier: 2, producingResumeData: true),
        ])
        XCTAssertEqual(machine.phase("d"), .paused, "paused items pick the policy up on resume")
        XCTAssertEqual(machine.defaultPolicy, .anyNetwork)
    }

    func testSetPolicyForOneItemResubmitsOnlyThatItem() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a", task: 1)
        try machine.enqueueAndBind("b", task: 2)

        let outcome = try machine.handle(.setPolicy(.anyNetwork, itemID("a")), now: referenceDate)

        XCTAssertEqual(outcome.submissions.map(\.itemID), [itemID("a")])
        XCTAssertEqual(machine.record("a")?.policy, .anyNetwork)
        XCTAssertNil(machine.record("b")?.policy)
    }

    func testSetPolicyEqualToEffectiveDefaultStoresWithoutResubmitting() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        let outcome = try machine.handle(.setPolicy(.unmeteredOnly, itemID("a")), now: referenceDate)
        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertEqual(machine.record("a")?.policy, .unmeteredOnly)
    }

    // MARK: helpers

    @discardableResult
    private func completed(_ machine: inout DownloadStateMachine, _ raw: String) throws -> UInt64 {
        let generation = try machine.enqueueAndBind(raw)
        _ = machine.send(.finished(reference(raw, generation: generation), captured: path("staging/\(raw)"), bytes: 10, validators: nil))
        _ = machine.handle(.finalized(itemID(raw), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)
        return generation
    }
}
