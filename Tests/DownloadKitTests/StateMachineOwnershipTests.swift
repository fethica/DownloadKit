//
//  StateMachineOwnershipTests.swift
//  DownloadKitTests
//
//  Unconfirmed attempts, one capture per attempt, the completion/stop linearisation point,
//  the planned finalisation destination, persisted cleanup intent and deferred restarts.
//

import XCTest
@testable import DownloadKit

final class StateMachineOwnershipTests: XCTestCase {

    private let cellular = NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true)
    private let wifi = NetworkPathStatus(isSatisfied: true)

    /// A record restored with intent but no binding, waiting for the policy.
    private func restoredWaitingRecord() throws -> DownloadStateMachine {
        var machine = DownloadStateMachine.fresh()
        _ = machine.handle(.pathChanged(cellular), now: referenceDate, jitter: 0)
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        XCTAssertEqual(machine.phase("a"), .waiting(.networkPolicy))
        XCTAssertNil(machine.record("a")?.binding)
        let contents = IndexContents(nextGeneration: machine.nextGeneration, records: Array(machine.records.values))
        return DownloadStateMachine(contents: contents, sessionIdentifier: "session", defaultPolicy: .default, retryPolicy: .default)
    }

    // MARK: unconfirmed attempts

    func testAllowedPathForAnUnconfirmedAttemptOnlyChangesTheExplanation() throws {
        var machine = try restoredWaitingRecord()
        let generation = machine.generation("a")

        let outcome = machine.handle(.pathChanged(wifi), now: referenceDate, jitter: 0)

        XCTAssertTrue(outcome.submissions.isEmpty, "a nil binding is not proof that the attempt ended")
        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(machine.generation("a"), generation)
    }

    func testPolicyChangeForAnUnconfirmedAttemptWaitsUntilItsTaskIsKnown() throws {
        var machine = try restoredWaitingRecord()
        let generation = machine.generation("a")

        let change = try machine.handle(.setDefaultPolicy(.anyNetwork), now: referenceDate)
        XCTAssertTrue(change.submissions.isEmpty)
        XCTAssertEqual(machine.generation("a"), generation)

        let bound = machine.handle(.taskBound(itemID("a"), generation: generation, taskIdentifier: 55), now: referenceDate, jitter: 0)

        XCTAssertEqual(bound.cancellations, [.cancelTask(itemID("a"), taskIdentifier: 55, producingResumeData: true)])
        XCTAssertEqual(bound.submissions.map(\.policy), [.anyNetwork], "the held-back change is applied once")
    }

    func testRetryIsRefusedForAnUnconfirmedWaitingAttempt() throws {
        var machine = try restoredWaitingRecord()
        let generation = machine.generation("a")

        let outcome = try machine.handle(.retry(itemID("a")), now: referenceDate)

        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertEqual(machine.generation("a"), generation)
    }

    func testAttemptProvenEndedByPolicyIsResubmittedOnceWhenThePathAllows() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .policyBlocked))
        XCTAssertEqual(machine.phase("a"), .waiting(.networkPolicy))

        let first = machine.handle(.pathChanged(wifi), now: referenceDate, jitter: 0)
        let second = machine.handle(.pathChanged(wifi), now: referenceDate, jitter: 0)

        XCTAssertEqual(first.submissions.count, 1)
        XCTAssertTrue(second.submissions.isEmpty)
    }

    // MARK: one capture per attempt

    func testReplayAfterARejectedValidationNeverCapturesAgain() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        let finished = TransferEvent.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil)
        _ = machine.send(finished)
        _ = machine.handle(.finalizationFailed(itemID("a"), generation: generation, .integrity), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.record("a")?.journal, .rejected)

        let replay = machine.send(finished)

        XCTAssertEqual(replay.effects, [.discardFile(path("staging/a"))])
        XCTAssertEqual(machine.record("a")?.journal, .rejected)
        XCTAssertNil(machine.record("a")?.stagingPath)
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .integrity)))

        let retry = try machine.handle(.retry(itemID("a")), now: referenceDate)
        XCTAssertEqual(retry.submissions.count, 1, "retry starts a fresh transfer, not a finalisation of deleted bytes")
        XCTAssertEqual(machine.record("a")?.journal, .notStarted)
    }

    // MARK: completion and stop linearisation

    func testFinalisationResultAfterCancelKeepsTheItemCancelledUntilRetry() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        let destination = RelativePath.media(generation: generation)

        let late = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: destination, integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)

        XCTAssertTrue(late.effects.isEmpty)
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
        XCTAssertEqual(machine.record("a")?.journal, .captured)
        XCTAssertTrue(machine.record("a")?.ownedPaths.contains(destination) == true, "the validated file stays with the record")

        let retry = try machine.handle(.retry(itemID("a")), now: referenceDate)
        XCTAssertEqual(retry.effects, [.finalize(itemID("a"), generation: generation, captured: path("staging/a"))])
        _ = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: destination, integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .completed(at: referenceDate))
    }

    func testFinalisationResultAfterPauseKeepsTheItemPaused() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        _ = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)

        XCTAssertEqual(machine.phase("a"), .paused)
        XCTAssertEqual(machine.record("a")?.journal, .captured)
    }

    func testRejectedValidationAfterCancelKeepsTheCancelledIntent() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        _ = machine.handle(.finalizationFailed(itemID("a"), generation: generation, .integrity), now: referenceDate, jitter: 0)

        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
        XCTAssertEqual(machine.record("a")?.journal, .rejected)
    }

    // MARK: ownership and cleanup intent

    func testRemovalOwnsThePlannedDestinationOfARunningFinalisation() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        XCTAssertEqual(machine.record("a")?.finalizationDestination, .media(generation: generation))

        let removal = try machine.handle(.remove(itemID("a")), now: referenceDate)

        let deletes = removal.effects.compactMap { effect -> [RelativePath]? in
            if case .deleteOwnedFiles(_, _, let paths) = effect { return paths } else { return nil }
        }
        XCTAssertEqual(deletes, [[path("staging/a"), .media(generation: generation)]])
    }

    func testDiscardsArePersistedAsCleanupIntentUntilVerified() throws {
        var machine = DownloadStateMachine.fresh()
        let stale = machine.send(.finished(reference("gone", generation: 9), captured: path("staging/stale"), bytes: 1, validators: nil))

        XCTAssertEqual(stale.effects, [.discardFile(path("staging/stale"))])
        XCTAssertEqual(stale.cleanupQueued, [path("staging/stale")])
        XCTAssertTrue(stale.hasStateChanges, "the intent is written before the deletion runs")
        XCTAssertEqual(machine.cleanup, [path("staging/stale")])

        let closed = machine.handle(.cleanupFinished(path("staging/stale")), now: referenceDate, jitter: 0)

        XCTAssertEqual(closed.cleanupCompleted, [path("staging/stale")])
        XCTAssertTrue(machine.cleanup.isEmpty)
    }

    func testRecordWithoutARecordedDestinationGetsTheImpliedOne() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        var record = try XCTUnwrap(machine.record("a"))
        record.finalizationDestination = nil

        let restored = DownloadStateMachine(contents: IndexContents(nextGeneration: machine.nextGeneration, records: [record]), sessionIdentifier: "session", defaultPolicy: .default, retryPolicy: .default)

        XCTAssertEqual(restored.record("a")?.finalizationDestination, .media(generation: generation))
    }

    // MARK: restart commands on an unconfirmed attempt

    /// A submission whose binding was never written: the attempt is unconfirmed.
    private func submittedUnbound() throws -> (DownloadStateMachine, UInt64) {
        var machine = DownloadStateMachine.fresh()
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        let generation = machine.generation("a")
        XCTAssertTrue(machine.isUnconfirmed(try XCTUnwrap(machine.record("a"))))
        return (machine, generation)
    }

    func testResumeAfterPauseOfAnUnconfirmedAttemptCreatesNoReplacement() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        let outcome = try machine.handle(.resume(itemID("a")), now: referenceDate)

        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertEqual(machine.generation("a"), generation)
        XCTAssertEqual(machine.phase("a"), .paused, "the stop stays in effect until the old attempt is known")
        XCTAssertTrue(machine.deferredRestarts.contains(itemID("a")))
    }

    func testRetryAfterCancelOfAnUnconfirmedAttemptCreatesNoReplacement() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        let outcome = try machine.handle(.retry(itemID("a")), now: referenceDate)

        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertEqual(machine.generation("a"), generation)
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
    }

    func testLateCompletionAfterADeferredRetryIsFinalisedNotDiscarded() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        _ = try machine.handle(.retry(itemID("a")), now: referenceDate)
        let captured = path("staging/late")

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: captured, bytes: 10, validators: nil))

        XCTAssertFalse(machine.cleanup.contains(captured), "the only downloaded copy is never queued for deletion")
        XCTAssertEqual(machine.record("a")?.stagingPath, captured)
        XCTAssertEqual(machine.phase("a"), .active)
        XCTAssertEqual(outcome.effects, [.finalize(itemID("a"), generation: generation, captured: captured)])
        XCTAssertFalse(machine.deferredRestarts.contains(itemID("a")))
    }

    func testLateCompletionAfterACancelWithoutRetryIsKeptWithTheRecord() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        let captured = path("staging/late")

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: captured, bytes: 10, validators: nil))

        XCTAssertFalse(machine.cleanup.contains(captured))
        XCTAssertEqual(machine.record("a")?.stagingPath, captured)
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
        XCTAssertTrue(outcome.effects.isEmpty)
    }

    func testFoundTaskIsAdoptedByADeferredResume() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        _ = try machine.handle(.resume(itemID("a")), now: referenceDate)

        let outcome = machine.handle(.taskBound(itemID("a"), generation: generation, taskIdentifier: 9), now: referenceDate, jitter: 0)

        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertTrue(outcome.cancellations.isEmpty)
        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(machine.record("a")?.binding?.taskIdentifier, 9)
        XCTAssertFalse(machine.isUnconfirmed(try XCTUnwrap(machine.record("a"))))
    }

    func testFoundTaskOfAStoppedUnconfirmedAttemptIsCancelledExactly() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        let outcome = machine.send(.progress(reference("a", generation: generation, task: 9), bytesWritten: 4, expectedBytes: 10))

        XCTAssertEqual(outcome.effects, [.cancelTask(itemID("a"), taskIdentifier: 9, producingResumeData: true)])
        XCTAssertEqual(machine.record("a")?.stoppingBinding?.taskIdentifier, 9)
        XCTAssertEqual(machine.phase("a"), .paused)

        let resumed = try machine.handle(.resume(itemID("a")), now: referenceDate)
        XCTAssertEqual(resumed.submissions.map(\.generation), [generation + 1], "the old attempt is known now")
    }

    func testProvenEndStartsTheDeferredRestartOnce() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        _ = try machine.handle(.resume(itemID("a")), now: referenceDate)

        let outcome = machine.handle(.submissionFailed(itemID("a"), generation: generation, .unknown), now: referenceDate, jitter: 0)
        let again = machine.handle(.orphanedIntent(itemID("a"), generation: generation), now: referenceDate, jitter: 0)

        XCTAssertEqual(outcome.submissions.map(\.generation), [generation + 1])
        XCTAssertTrue(again.submissions.isEmpty)
    }

    func testPauseAfterADeferredResumeDropsIt() throws {
        var (machine, generation) = try submittedUnbound()
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        _ = try machine.handle(.resume(itemID("a")), now: referenceDate)
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        let outcome = machine.handle(.orphanedIntent(itemID("a"), generation: generation), now: referenceDate, jitter: 0)

        XCTAssertTrue(outcome.submissions.isEmpty, "the latest command was a pause")
        XCTAssertEqual(machine.phase("a"), .paused)
    }
}
