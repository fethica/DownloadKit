//
//  StateMachineEventTests.swift
//  DownloadKitTests
//
//  Event transitions, stale-generation rejection, retries and path explanations.
//

import XCTest
@testable import DownloadKit

final class StateMachineEventTests: XCTestCase {

    // MARK: progress and waiting

    func testProgressMovesQueuedToActiveAndRecordsBytes() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")

        _ = machine.send(.progress(reference("a", generation: generation), bytesWritten: 40, expectedBytes: 100))

        XCTAssertEqual(machine.phase("a"), .active)
        XCTAssertEqual(machine.record("a")?.bytesWritten, 40)
        XCTAssertEqual(machine.record("a")?.snapshot.progress, 0.4)
    }

    func testProgressWithoutKnownLengthIsIndeterminate() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.progress(reference("a", generation: generation), bytesWritten: 40, expectedBytes: nil))
        XCTAssertNil(machine.record("a")?.snapshot.progress)
    }

    func testProgressAfterPauseIsIgnored() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        let outcome = machine.send(.progress(reference("a", generation: generation), bytesWritten: 99, expectedBytes: 100))

        XCTAssertEqual(machine.phase("a"), .paused)
        XCTAssertFalse(outcome.hasStateChanges)
    }

    func testWaitingEventRecordsReasonAndCannotClaimARetrySchedule() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")

        _ = machine.send(.waiting(reference("a", generation: generation), .connectivity))
        XCTAssertEqual(machine.phase("a"), .waiting(.connectivity))

        _ = machine.send(.waiting(reference("a", generation: generation), .retryScheduled(at: referenceDate)))
        XCTAssertEqual(machine.phase("a"), .waiting(.unknown))
    }

    // MARK: stale generations

    func testStaleProgressCannotResurrectARemovedItem() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)
        _ = machine.handle(.removalFinished(itemID("a"), generation: machine.generation("a")), now: referenceDate, jitter: 0)

        let outcome = machine.send(.progress(reference("a", generation: generation), bytesWritten: 1, expectedBytes: 2))

        XCTAssertTrue(outcome.ignoredStale)
        XCTAssertNil(machine.record("a"))
    }

    func testStaleCompletionAfterRemovalDiscardsTheCapturedFile() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: path("staging/late"), bytes: 10, validators: nil))

        XCTAssertTrue(outcome.ignoredStale)
        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/late"))])
        XCTAssertEqual(machine.phase("a"), .removing)
    }

    func testEventsFromAnEarlierIncarnationNeverMatchAReEnqueuedItem() throws {
        var machine = DownloadStateMachine.fresh()
        let first = try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)
        _ = machine.handle(.removalFinished(itemID("a"), generation: machine.generation("a")), now: referenceDate, jitter: 0)
        let second = try machine.enqueueAndBind("a")

        XCTAssertGreaterThan(second, first)
        let outcome = machine.send(.finished(reference("a", generation: first), captured: path("staging/old"), bytes: 10, validators: nil))

        XCTAssertTrue(outcome.ignoredStale)
        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/old"))])
    }

    func testStaleFailureAfterResumeDoesNotFailTheNewAttempt() throws {
        var machine = DownloadStateMachine.fresh()
        let first = try machine.enqueueAndBind("a")
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        _ = try machine.handle(.resume(itemID("a")), now: referenceDate)

        let outcome = machine.send(.failed(reference("a", generation: first), .cancelled))

        XCTAssertTrue(outcome.ignoredStale)
        XCTAssertEqual(machine.phase("a"), .queued)
    }

    func testStaleTaskBindingCancelsTheOrphanTask() throws {
        var machine = DownloadStateMachine.fresh()
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)
        let generation = machine.generation("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)

        let outcome = machine.handle(.taskBound(itemID("a"), generation: generation, taskIdentifier: 77), now: referenceDate, jitter: 0)

        XCTAssertEqual(outcome.effects, [.cancelTask(itemID("a"), taskIdentifier: 77, producingResumeData: false)])
    }

    func testStaleRemovalFinishedAndRetryDueAreIgnored() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        XCTAssertTrue(machine.handle(.removalFinished(itemID("a"), generation: generation + 10), now: referenceDate, jitter: 0).ignoredStale)
        XCTAssertTrue(machine.handle(.retryDue(itemID("a"), generation: generation + 10), now: referenceDate, jitter: 0).ignoredStale)
        XCTAssertEqual(machine.phase("a"), .queued)
    }

    // MARK: completion and finalisation

    func testFinishedCapturesAndRequestsFinalisationWithoutCompleting() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        let validators = ResponseValidators(entityTag: "\"v1\"")

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: validators))

        XCTAssertEqual(machine.phase("a"), .active, "bytes are not playable before validation")
        XCTAssertEqual(machine.record("a")?.journal, .captured)
        XCTAssertEqual(machine.record("a")?.stagingPath, path("staging/a"))
        XCTAssertEqual(machine.record("a")?.validators, validators)
        XCTAssertEqual(outcome.effects, [.finalize(itemID("a"), generation: generation, captured: path("staging/a"))])
    }

    func testDuplicateFinishedDiscardsTheSecondFile() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/one"), bytes: 10, validators: nil))

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: path("staging/two"), bytes: 10, validators: nil))

        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/two"))])
        XCTAssertEqual(machine.record("a")?.stagingPath, path("staging/one"))
    }

    func testFinishedAfterCancelIsDiscarded() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))

        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/a"))])
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
    }

    func testFinishedWhilePausedKeepsTheCompletedBytes() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))

        XCTAssertEqual(outcome.effects, [.finalize(itemID("a"), generation: generation, captured: path("staging/a"))])
    }

    func testFinalizedCommitsCompletion() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        let later = referenceDate.addingTimeInterval(30)

        _ = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 10)), now: later, jitter: 0)

        let record = try XCTUnwrap(machine.record("a"))
        XCTAssertEqual(record.phase, .completed(at: later))
        XCTAssertEqual(record.journal, .committed)
        XCTAssertNil(record.stagingPath)
        XCTAssertEqual(record.finalPath, .media(generation: generation))
        XCTAssertEqual(record.snapshot.progress, 1)
        XCTAssertTrue(record.snapshot.isAvailableOffline)
    }

    func testFinalizedWithoutCapturedJournalIsIgnored() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        let outcome = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 1)), now: referenceDate, jitter: 0)
        XCTAssertFalse(outcome.hasStateChanges)
        XCTAssertEqual(machine.phase("a"), .queued)
    }

    func testFinalisationFailureFailsAndDiscardsCapturedBytes() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))

        let outcome = machine.handle(.finalizationFailed(itemID("a"), generation: generation, .integrity), now: referenceDate, jitter: 0)

        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .integrity)))
        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/a"))])
        XCTAssertEqual(machine.record("a")?.journal, .notStarted)
    }

    func testReplacementOfCorruptFileDiscardsOldFileOnlyAfterNewOneCommits() throws {
        var machine = DownloadStateMachine.fresh()
        let first = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: first), captured: path("staging/1"), bytes: 10, validators: nil))
        _ = machine.handle(.finalized(itemID("a"), generation: first, finalPath: .media(generation: first), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)
        _ = machine.handle(.fileCorrupt(itemID("a"), generation: first), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .integrity)))

        let retry = try machine.handle(.retry(itemID("a")), now: referenceDate)
        XCTAssertFalse(retry.effects.contains(.discardFile(.media(generation: first))))
        let second = machine.generation("a")
        _ = machine.handle(.taskBound(itemID("a"), generation: second, taskIdentifier: 8), now: referenceDate, jitter: 0)
        _ = machine.send(.finished(reference("a", generation: second, task: 8), captured: path("staging/2"), bytes: 10, validators: nil))
        let commit = machine.handle(.finalized(itemID("a"), generation: second, finalPath: .media(generation: second), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)

        XCTAssertEqual(commit.effects, [.discardFile(.media(generation: first))])
        XCTAssertEqual(machine.record("a")?.finalPath, .media(generation: second))
    }

    func testFileMissingTurnsCompletedIntoMissing() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))
        _ = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)

        _ = machine.handle(.fileMissing(itemID("a"), generation: generation), now: referenceDate, jitter: 0)

        XCTAssertEqual(machine.record("a")?.snapshot.state, .missing)
        XCTAssertNil(machine.record("a")?.finalPath)
    }

    // MARK: failures and retries

    func testTransientFailureSchedulesBoundedRetriesWithJitter() throws {
        let policy = RetryPolicy(maximumAutomaticRetries: 3, baseDelay: 2, maximumDelay: 300)
        var machine = DownloadStateMachine.fresh(retry: policy)
        var generation = try machine.enqueueAndBind("a")
        var now = referenceDate
        let expectedDelays: [TimeInterval] = [1.5, 3, 6] // jitter 0.5 -> 75% of 2, 4, 8

        for (index, delay) in expectedDelays.enumerated() {
            let outcome = machine.send(.failed(reference("a", generation: generation), .network(code: -1005)), now: now, jitter: 0.5)
            let due = now.addingTimeInterval(delay)
            XCTAssertEqual(machine.phase("a"), .waiting(.retryScheduled(at: due)), "retry \(index)")
            XCTAssertEqual(outcome.effects, [.scheduleRetry(itemID("a"), generation: generation, at: due)])
            XCTAssertEqual(machine.record("a")?.automaticRetryCount, index + 1)
            now = due
            let resubmit = machine.handle(.retryDue(itemID("a"), generation: generation), now: now, jitter: 0)
            XCTAssertEqual(resubmit.submissions.count, 1)
            generation = machine.generation("a")
            _ = machine.handle(.taskBound(itemID("a"), generation: generation, taskIdentifier: 7), now: now, jitter: 0)
        }

        _ = machine.send(.failed(reference("a", generation: generation), .network(code: -1005)), now: now, jitter: 0.5)
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .network)))
        XCTAssertNil(machine.record("a")?.retryAt)
    }

    func testRetryAfterIsHonoured() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")

        _ = machine.send(.failed(reference("a", generation: generation), .http(status: 503, retryAfter: 120)), jitter: 0)

        XCTAssertEqual(machine.record("a")?.retryAt, referenceDate.addingTimeInterval(120))
    }

    func testPermanentHTTPFailureDoesNotRetry() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        let outcome = machine.send(.failed(reference("a", generation: generation), .http(status: 404, retryAfter: nil)))
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .http, httpStatus: 404)))
        XCTAssertTrue(outcome.effects.isEmpty)
    }

    func testAuthenticationFailureIsTypedAsUnauthorized() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .http(status: 401, retryAfter: nil)))
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .unauthorized, httpStatus: 401)))
    }

    func testStorageAndIntegrityFailuresAreTypedAndNotRetried() throws {
        var machine = DownloadStateMachine.fresh()
        let a = try machine.enqueueAndBind("a")
        let b = try machine.enqueueAndBind("b")
        _ = machine.send(.failed(reference("a", generation: a), .storage(.diskFull)))
        _ = machine.send(.failed(reference("b", generation: b), .integrity))
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .storageFull)))
        XCTAssertEqual(machine.phase("b"), .failed(DownloadFailure(kind: .integrity)))
    }

    func testPolicyRefusalWaitsWithoutSpendingAnAttempt() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")

        let outcome = machine.send(.failed(reference("a", generation: generation), .policyBlocked))

        XCTAssertEqual(machine.phase("a"), .waiting(.networkPolicy))
        XCTAssertEqual(machine.record("a")?.automaticRetryCount, 0)
        XCTAssertTrue(outcome.effects.isEmpty)
    }

    func testFailureEchoAfterPauseIsIgnored() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)

        _ = machine.send(.failed(reference("a", generation: generation), .cancelled))

        XCTAssertEqual(machine.phase("a"), .paused)
    }

    func testSubmissionFailureIsClassifiedLikeATransferFailure() throws {
        var machine = DownloadStateMachine.fresh()
        _ = try machine.handle(.enqueue(makeRequest("a")), now: referenceDate)

        _ = machine.handle(.submissionFailed(itemID("a"), generation: machine.generation("a"), .storage(.permissionDenied)), now: referenceDate, jitter: 0)

        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .storage)))
    }

    // MARK: resume data

    func testResumeDataForAStaleAttemptIsDiscarded() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)

        let outcome = machine.send(.resumeDataCaptured(reference("a", generation: generation), path("staging/r")))

        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/r"))])
    }

    func testNewerResumeDataReplacesOlder() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        _ = machine.send(.resumeDataCaptured(reference("a", generation: generation), path("staging/r1")))

        let outcome = machine.send(.resumeDataCaptured(reference("a", generation: generation), path("staging/r2")))

        XCTAssertEqual(outcome.effects, [.discardFile(path("staging/r1"))])
        XCTAssertEqual(machine.record("a")?.resumeDataPath, path("staging/r2"))
    }

    // MARK: reconciliation and path explanations

    func testOrphanedIntentResubmitsUnderANewGeneration() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")

        let outcome = machine.handle(.orphanedIntent(itemID("a")), now: referenceDate, jitter: 0)

        XCTAssertEqual(outcome.submissions.count, 1)
        XCTAssertGreaterThan(machine.generation("a"), generation)
    }

    func testOrphanedIntentNeverResubmitsCapturedBytes() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))

        let outcome = machine.handle(.orphanedIntent(itemID("a")), now: referenceDate, jitter: 0)

        XCTAssertTrue(outcome.effects.isEmpty)
        XCTAssertEqual(machine.record("a")?.journal, .captured)
    }

    func testDisallowedPathExplainsWaitingAndAllowedPathRestoresQueued() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        try machine.enqueueAndBind("b", request: makeRequest("b", policy: .anyNetwork))

        let cellular = NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true)
        let toCellular = machine.handle(.pathChanged(cellular), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .waiting(.networkPolicy))
        XCTAssertEqual(machine.phase("b"), .queued)
        XCTAssertTrue(toCellular.effects.isEmpty, "explanations never create or cancel tasks")

        let wifi = NetworkPathStatus(isSatisfied: true)
        let back = machine.handle(.pathChanged(wifi), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .queued)
        XCTAssertTrue(back.effects.isEmpty)
    }

    func testLostConnectivityIsExplainedAsConnectivity() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        _ = machine.handle(.pathChanged(NetworkPathStatus(isSatisfied: false)), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .waiting(.connectivity))
    }

    func testPolicyRefusedAttemptResubmitsOnceWhenPathAllows() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.failed(reference("a", generation: generation), .policyBlocked))

        let first = machine.handle(.pathChanged(NetworkPathStatus(isSatisfied: true)), now: referenceDate, jitter: 0)
        let second = machine.handle(.pathChanged(NetworkPathStatus(isSatisfied: true)), now: referenceDate, jitter: 0)

        XCTAssertEqual(first.submissions.count, 1)
        XCTAssertTrue(second.submissions.isEmpty)
    }

    // MARK: determinism and persistence restore

    func testSameInputsProduceIdenticalMachines() throws {
        func run() throws -> DownloadStateMachine {
            var machine = DownloadStateMachine.fresh()
            let generation = try machine.enqueueAndBind("a")
            _ = machine.send(.progress(reference("a", generation: generation), bytesWritten: 5, expectedBytes: 10))
            _ = try machine.handle(.pause(itemID("a")), now: referenceDate.addingTimeInterval(1))
            _ = try machine.handle(.resume(itemID("a")), now: referenceDate.addingTimeInterval(2))
            _ = try machine.handle(.remove(itemID("a")), now: referenceDate.addingTimeInterval(3))
            return machine
        }
        XCTAssertEqual(try run(), try run())
    }

    func testRestoredMachineNeverReusesAGeneration() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        try machine.enqueueAndBind("b")
        let contents = IndexContents(nextGeneration: 1, records: Array(machine.records.values))

        var restored = DownloadStateMachine(contents: contents, sessionIdentifier: "session", defaultPolicy: .default, retryPolicy: .default)
        _ = try restored.handle(.enqueue(makeRequest("c")), now: referenceDate)

        XCTAssertEqual(restored.generation("c"), 3)
    }

    func testPersistedDefaultPolicyWinsOverConfiguredDefault() {
        let contents = IndexContents(defaultPolicy: .anyNetwork)
        let machine = DownloadStateMachine(contents: contents, sessionIdentifier: "s", defaultPolicy: .unmeteredOnly, retryPolicy: .default)
        XCTAssertEqual(machine.defaultPolicy, .anyNetwork)
    }
}
