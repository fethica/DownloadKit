//
//  StateMachineCaptureTests.swift
//  DownloadKitTests
//
//  Captured bytes stay owned by their record and their generation: duplicate and late
//  completions, pause/cancel/retry of a captured item, stop bindings and fresh attempts.
//

import XCTest
@testable import DownloadKit

final class StateMachineCaptureTests: XCTestCase {

    private func captured(_ machine: inout DownloadStateMachine, _ raw: String = "a", file: String = "staging/a") throws -> UInt64 {
        let generation = try machine.enqueueAndBind(raw)
        _ = machine.send(.finished(reference(raw, generation: generation), captured: path(file), bytes: 10, validators: nil))
        return generation
    }

    func testReplayedCompletionWithTheSamePathIsANoOp() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try captured(&machine)

        let outcome = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: nil))

        XCTAssertTrue(outcome.effects.isEmpty, "a replay must not delete the capture it repeats")
        XCTAssertEqual(machine.record("a")?.stagingPath, path("staging/a"))
    }

    func testCancelAfterCaptureKeepsTheBytes() throws {
        var machine = DownloadStateMachine.fresh()
        _ = try captured(&machine)

        let outcome = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        XCTAssertFalse(outcome.effects.contains { if case .discardFile = $0 { return true } else { return false } })
        XCTAssertEqual(machine.phase("a"), .failed(DownloadFailure(kind: .cancelled)))
        XCTAssertEqual(machine.record("a")?.journal, .captured)
        XCTAssertEqual(machine.record("a")?.ownedPaths, [path("staging/a")])
    }

    func testStaleCompletionKeepsAFileAnotherRecordOwns() throws {
        var machine = DownloadStateMachine.fresh()
        _ = try captured(&machine, "a", file: "staging/shared")
        let b = try machine.enqueueAndBind("b")
        _ = try machine.handle(.remove(itemID("b")), now: referenceDate)

        let outcome = machine.send(.finished(reference("b", generation: b), captured: path("staging/shared"), bytes: 10, validators: nil))

        XCTAssertTrue(outcome.ignoredStale)
        XCTAssertTrue(outcome.effects.isEmpty, "a path owned by a live record is never discarded")
    }

    func testCapturedPauseResumeRecoversFinalisationForTheSameGeneration() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try captured(&machine)

        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        XCTAssertEqual(machine.phase("a"), .paused)
        let resume = try machine.handle(.resume(itemID("a")), now: referenceDate)

        XCTAssertEqual(resume.effects, [.finalize(itemID("a"), generation: generation, captured: path("staging/a"))])
        XCTAssertTrue(resume.submissions.isEmpty, "no transfer is started over captured bytes")
        XCTAssertEqual(machine.generation("a"), generation)

        _ = machine.handle(.finalized(itemID("a"), generation: generation, finalPath: .media(generation: generation), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)
        XCTAssertEqual(machine.phase("a"), .completed(at: referenceDate))
    }

    func testCapturedCancelRetryRecoversFinalisationForTheSameGeneration() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try captured(&machine)

        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)
        let retry = try machine.handle(.retry(itemID("a")), now: referenceDate)

        XCTAssertEqual(retry.effects, [.finalize(itemID("a"), generation: generation, captured: path("staging/a"))])
        XCTAssertEqual(machine.phase("a"), .active)
        XCTAssertEqual(machine.generation("a"), generation)
    }

    func testFinalisationResultForAnotherGenerationIsIgnored() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try captured(&machine)

        let outcome = machine.handle(.finalized(itemID("a"), generation: generation + 1, finalPath: .media(generation: generation + 1), integrity: IntegrityRecord(verifiedLength: 10)), now: referenceDate, jitter: 0)

        XCTAssertTrue(outcome.ignoredStale)
        XCTAssertEqual(machine.record("a")?.journal, .captured)
    }

    func testFreshAttemptResetsBytesAndValidators() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")
        _ = machine.send(.progress(reference("a", generation: generation), bytesWritten: 40, expectedBytes: 100))
        _ = try machine.handle(.cancel(itemID("a")), now: referenceDate)

        _ = try machine.handle(.retry(itemID("a")), now: referenceDate)

        XCTAssertEqual(machine.record("a")?.bytesWritten, 0)
        XCTAssertNil(machine.record("a")?.expectedBytes)
        XCTAssertNil(machine.record("a")?.validators)
    }

    func testStopKeepsTheBindingUntilAcknowledged() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a", task: 9)

        _ = try machine.handle(.pause(itemID("a")), now: referenceDate)
        XCTAssertNil(machine.record("a")?.binding)
        XCTAssertEqual(machine.record("a")?.stoppingBinding, TaskBinding(sessionIdentifier: "session", taskIdentifier: 9, generation: generation))

        let other = machine.handle(.stopAcknowledged(itemID("a"), taskIdentifier: 8), now: referenceDate, jitter: 0)
        XCTAssertFalse(other.hasStateChanges)
        _ = machine.handle(.stopAcknowledged(itemID("a"), taskIdentifier: 9), now: referenceDate, jitter: 0)
        XCTAssertNil(machine.record("a")?.stoppingBinding)
    }

    func testRemovalKeepsTheOldAttemptInTheStoppingBinding() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a", task: 9)

        _ = try machine.handle(.remove(itemID("a")), now: referenceDate)

        XCTAssertGreaterThan(machine.generation("a"), generation)
        XCTAssertEqual(machine.record("a")?.stoppingBinding?.generation, generation)
    }

    func testOrphanedIntentForAnOlderGenerationIsIgnored() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a")

        let outcome = machine.handle(.orphanedIntent(itemID("a"), generation: generation - 1), now: referenceDate, jitter: 0)

        XCTAssertTrue(outcome.submissions.isEmpty)
        XCTAssertEqual(machine.generation("a"), generation)
    }

    func testCredentialsInTheSourceURLAreRejected() {
        var machine = DownloadStateMachine.fresh()
        XCTAssertThrowsError(try machine.handle(.enqueue(makeRequest("a", url: "https://user:secret@media.example.com/a.m4a")), now: referenceDate)) { error in
            XCTAssertEqual(error as? DownloadError, .credentialsInURL(itemID("a")))
        }
        XCTAssertNil(machine.record("a"))
    }
}
