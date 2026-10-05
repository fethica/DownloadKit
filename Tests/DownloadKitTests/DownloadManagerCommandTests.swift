//
//  DownloadManagerCommandTests.swift
//  DownloadKitTests
//
//  Commands and events through the actor: ordering, persistence-before-effects, stale events,
//  leases, retries, policy and the snapshot stream.
//

import XCTest
@testable import DownloadKit

final class DownloadManagerCommandTests: XCTestCase {

    private func started(_ harness: Harness, urlRefresher: (any URLRefreshing)? = nil) async throws -> DownloadManager {
        let manager = harness.makeManager(urlRefresher: urlRefresher)
        try await manager.start()
        return manager
    }

    // MARK: ordering and persistence

    func testIntentIsPersistedBeforeTheTaskIsSubmittedAndTheBindingAfter() async throws {
        let harness = try Harness()
        let manager = try await started(harness)

        let snapshot = try await manager.enqueue(makeRequest("a"))

        let entries = await harness.log.entries
        XCTAssertEqual(entries, ["persist a", "submit a g1", "persist a"])
        XCTAssertEqual(snapshot.state, .queued)
        let stored = await harness.store.contents?.records.first
        XCTAssertEqual(stored?.binding?.taskIdentifier, 101)
        XCTAssertEqual(stored?.binding?.sessionIdentifier, harness.sessionIdentifier)
        XCTAssertEqual(stored?.generation, 1)
    }

    func testDuplicateEnqueueSubmitsOnce() async throws {
        let harness = try Harness()
        let manager = try await started(harness)

        try await manager.enqueue(makeRequest("a"))
        try await manager.enqueue(makeRequest("a"))
        try await manager.enqueue(makeRequest("a", url: "https://mirror.example.com/one.m4a"))

        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.count, 1)
        let stored = await harness.store.contents?.records.first?.request.sourceURL.host
        XCTAssertEqual(stored, "mirror.example.com")
    }

    func testConflictingRevisionIsRejectedAndKeepsTheRecord() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))

        await assertThrows(.conflictingRequest(itemID("a"))) { try await manager.enqueue(makeRequest("a", revision: "r2")) }

        let revision = await manager.snapshot(for: itemID("a"))?.revision
        XCTAssertEqual(revision, ContentRevision("r1"))
    }

    func testRejectedIndexWriteLeavesStateUnchangedAndStartsNothing() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        await harness.store.setFailWrites(true)

        await assertThrows(.persistenceFailed) { try await manager.enqueue(makeRequest("a")) }

        let snapshot = await manager.snapshot(for: itemID("a"))
        let submissions = await harness.session.submissions
        XCTAssertNil(snapshot)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testConcurrentCommandsAreSerialised() async throws {
        let harness = try Harness()
        let manager = try await started(harness)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try await manager.enqueue(makeRequest("item-\(index)")) }
            }
            try await group.waitForAll()
        }

        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.count, 20)
        XCTAssertEqual(Set(submissions.map(\.generation)), Set(1...20))
        let stored = await harness.store.contents
        XCTAssertEqual(stored?.records.count, 20)
        XCTAssertEqual(stored?.nextGeneration, 21)
    }

    func testPauseResumeAndCancelReachTheSession() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))

        try await manager.pause(itemID("a"))
        try await manager.resume(itemID("a"))
        try await manager.cancel(itemID("a"))

        let cancellations = await harness.session.cancellations
        let submissions = await harness.session.submissions
        XCTAssertEqual(cancellations, [
            .init(taskIdentifier: 101, producingResumeData: true),
            .init(taskIdentifier: 102, producingResumeData: true),
        ])
        XCTAssertEqual(submissions.map(\.generation), [1, 2])
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(state, .failed(DownloadFailure(kind: .cancelled)))
    }

    func testSubmissionFailureIsClassified() async throws {
        let harness = try Harness()
        await harness.session.setSubmitFailure(.http(status: 404, retryAfter: nil))
        let manager = try await started(harness)

        try await manager.enqueue(makeRequest("a"))

        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(state, .failed(DownloadFailure(kind: .http, httpStatus: 404)))
    }

    // MARK: events

    func testSessionEventsAreAppliedInOrder() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a", expectedLength: 30))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        let captured = path("staging/a")
        await harness.fileSystem.putFile(harness.url(captured), size: 30)

        await harness.session.emit(.progress(reference, bytesWritten: 10, expectedBytes: 30))
        await harness.session.emit(.progress(reference, bytesWritten: 20, expectedBytes: 30))
        await harness.session.emit(.waiting(reference, .connectivity))
        await harness.session.emit(.progress(reference, bytesWritten: 30, expectedBytes: 30))
        await harness.session.emit(.finished(reference, captured: captured, bytes: 30, validators: nil))

        await eventually("item completes") { await manager.snapshot(for: itemID("a"))?.isAvailableOffline == true }
        let snapshot = await manager.snapshot(for: itemID("a"))
        XCTAssertEqual(snapshot?.bytesWritten, 30)
        let finalExists = await harness.fileSystem.hasFile(harness.url(.media(generation: 1)))
        let capturedExists = await harness.fileSystem.hasFile(harness.url(captured))
        XCTAssertTrue(finalExists)
        XCTAssertFalse(capturedExists)
    }

    func testStaleEventsAfterRemovalCannotResurrectAndTheirFilesAreDiscarded() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        try await manager.remove(itemID("a"))
        let afterRemove = await manager.state(for: itemID("a"))
        XCTAssertEqual(afterRemove, .notDownloaded)

        let lateFile = path("staging/late")
        await harness.fileSystem.putFile(harness.url(lateFile), size: 10)
        await manager.engine.ingest(.transfer(.progress(reference, bytesWritten: 5, expectedBytes: 10)))
        await manager.engine.ingest(.transfer(.finished(reference, captured: lateFile, bytes: 10, validators: nil)))

        let state = await manager.state(for: itemID("a"))
        let lateExists = await harness.fileSystem.hasFile(harness.url(lateFile))
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertFalse(lateExists)

        try await manager.enqueue(makeRequest("a"))
        await manager.engine.ingest(.transfer(.failed(reference, .http(status: 404, retryAfter: nil))))
        let reEnqueued = await manager.state(for: itemID("a"))
        XCTAssertEqual(reEnqueued, .queued, "an event from the removed incarnation cannot fail the new one")
    }

    func testDeferredFinalisationNeverMarksBytesCompleted() async throws {
        let harness = try Harness()
        await harness.finalizer.setMode(.deferred)
        let manager = try await started(harness)

        try await completeItem("a", manager: manager, harness: harness)

        let state = await manager.state(for: itemID("a"))
        let journal = await harness.store.contents?.records.first?.journal
        XCTAssertEqual(state, .active)
        XCTAssertEqual(journal, .captured)
        let lookup = try await manager.localFile(for: itemID("a"))
        XCTAssertEqual(lookup, .unavailable(.inProgress))
    }

    func testFinalisationFailureDiscardsCapturedBytes() async throws {
        let harness = try Harness()
        await harness.finalizer.setMode(.fail(.integrity))
        let manager = try await started(harness)

        try await completeItem("a", manager: manager, harness: harness)

        let state = await manager.state(for: itemID("a"))
        let capturedExists = await harness.fileSystem.hasFile(harness.url(path("staging/a-1")))
        XCTAssertEqual(state, .failed(DownloadFailure(kind: .integrity)))
        XCTAssertFalse(capturedExists)
    }

    // MARK: local files and leases

    func testCompletedFileIsLeasedAndRemovalWaitsForTheLease() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await completeItem("a", manager: manager, harness: harness)
        try await completeItem("b", manager: manager, harness: harness)

        guard case .available(let lease) = try await manager.localFile(for: itemID("a")) else {
            return XCTFail("expected an available file")
        }
        XCTAssertEqual(lease.url, harness.url(.media(generation: 1)))

        try await manager.remove(itemID("a"))
        let removing = await manager.state(for: itemID("a"))
        let stillThere = await harness.fileSystem.hasFile(lease.url)
        XCTAssertEqual(removing, .removing)
        XCTAssertTrue(stillThere, "a held lease keeps the file")
        let duringRemoval = try await manager.localFile(for: itemID("a"))
        XCTAssertEqual(duringRemoval, .unavailable(.removing))

        await manager.endAccess(lease)

        let gone = await manager.state(for: itemID("a"))
        let fileGone = await harness.fileSystem.hasFile(lease.url)
        let other = await harness.fileSystem.hasFile(harness.url(.media(generation: 2)))
        XCTAssertEqual(gone, .notDownloaded)
        XCTAssertFalse(fileGone)
        XCTAssertTrue(other, "removing one item never touches another item's file")
    }

    func testExternallyDeletedFileIsReportedMissing() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await completeItem("a", manager: manager, harness: harness)
        try await harness.fileSystem.removeItem(at: harness.url(.media(generation: 1)))

        let lookup = try await manager.localFile(for: itemID("a"))

        XCTAssertEqual(lookup, .unavailable(.missing))
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(state, .missing)
    }

    func testSizeMismatchIsReportedCorrupt() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await completeItem("a", manager: manager, harness: harness)
        await harness.fileSystem.putFile(harness.url(.media(generation: 1)), size: 3)

        let lookup = try await manager.localFile(for: itemID("a"))

        XCTAssertEqual(lookup, .unavailable(.corrupt))
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(state, .failed(DownloadFailure(kind: .integrity)))
    }

    func testLookupOfUnknownAndInProgressItems() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))

        let unknown = try await manager.localFile(for: itemID("x"))
        let inProgress = try await manager.localFile(for: itemID("a"))
        XCTAssertEqual(unknown, .unavailable(.notDownloaded))
        XCTAssertEqual(inProgress, .unavailable(.inProgress))
    }

    func testWithLocalFileHoldsAndReleasesTheLease() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await completeItem("a", manager: manager, harness: harness)

        let name = try await manager.withLocalFile(for: itemID("a")) { url in url.lastPathComponent }

        XCTAssertEqual(name, "item-1")
        let leases = await manager.engine.activeLeaseCount
        XCTAssertEqual(leases, 0)
        await assertThrows(.fileUnavailable(.notDownloaded)) {
            _ = try await manager.withLocalFile(for: itemID("x")) { $0 }
        }
    }

    // MARK: retries

    func testTransientFailureRetriesWhenTheClockReachesTheDueTime() async throws {
        let harness = try Harness(retryPolicy: RetryPolicy(baseDelay: 2), jitter: 1)
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))

        await manager.engine.ingest(.transfer(.failed(reference, .network(code: -1009))))

        let due = referenceDate.addingTimeInterval(2)
        let state = await manager.state(for: itemID("a"))
        XCTAssertEqual(state, .waiting(.retryScheduled(at: due)))
        await eventually("retry timer registered") { await harness.clock.sleeperCount == 1 }
        let deadlines = await harness.clock.deadlines
        XCTAssertEqual(deadlines, [due])

        await harness.clock.advance(by: 2)

        await eventually("retry submitted") { await harness.session.submissions.count == 2 }
        let snapshot = await manager.snapshot(for: itemID("a"))
        XCTAssertEqual(snapshot?.automaticRetryCount, 1)
    }

    func testCancelStopsAScheduledRetry() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        await manager.engine.ingest(.transfer(.failed(reference, .network(code: nil))))
        await eventually("retry timer registered") { await harness.clock.sleeperCount == 1 }

        try await manager.cancel(itemID("a"))

        await eventually("retry timer cancelled") { await harness.clock.sleeperCount == 0 }
        await harness.clock.advance(by: 3600)
        await manager.engine.fireDueRetries()
        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.count, 1)
    }

    func testRetryAfterUnauthorizedAsksTheHostForAFreshURL() async throws {
        struct Refresher: URLRefreshing {
            func refreshedURL(for id: DownloadID, metadata: DownloadMetadata) async throws -> URL {
                URL(string: "https://media.example.com/fresh/\(id.rawValue).m4a")!
            }
        }
        let harness = try Harness()
        let manager = try await started(harness, urlRefresher: Refresher())
        try await manager.enqueue(makeRequest("a"))
        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        await manager.engine.ingest(.transfer(.failed(reference, .http(status: 403, retryAfter: nil))))

        try await manager.retry(itemID("a"))

        let latest = await harness.session.submissions.last
        XCTAssertEqual(latest?.url.path, "/fresh/a.m4a")
        let snapshot = await manager.snapshot(for: itemID("a"))
        XCTAssertEqual(snapshot?.revision, ContentRevision("r1"))
    }

    // MARK: policy

    func testDefaultPolicyChangeResubmitsWithoutDuplicateTasks() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))
        try await manager.enqueue(makeRequest("b"))

        try await manager.setDefaultPolicy(.anyNetwork)
        try await manager.setDefaultPolicy(.anyNetwork)

        let submissions = await harness.session.submissions
        let cancellations = await harness.session.cancellations
        let live = await harness.session.systemTasks()
        XCTAssertEqual(submissions.count, 4)
        XCTAssertEqual(cancellations.count, 2)
        XCTAssertEqual(live.count, 2, "exactly one live task per item")
        XCTAssertEqual(Array(submissions.suffix(2)).map(\.policy), [.anyNetwork, .anyNetwork])
        let stored = await harness.store.contents?.defaultPolicy
        XCTAssertEqual(stored, .anyNetwork)
    }

    func testPathObservationExplainsWaiting() async throws {
        let pathSource = FakePathSource(NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true))
        let harness = try Harness(pathSource: pathSource)
        let manager = try await started(harness)

        try await manager.enqueue(makeRequest("a"))
        let waiting = await manager.state(for: itemID("a"))
        XCTAssertEqual(waiting, .waiting(.networkPolicy))

        await pathSource.publish(NetworkPathStatus(isSatisfied: true))

        await eventually("explanation cleared") { await manager.state(for: itemID("a")) == .queued }
        let submissions = await harness.session.submissions
        XCTAssertEqual(submissions.count, 1, "an explanation never creates a duplicate task")
    }

    // MARK: snapshot stream

    func testSnapshotStreamStartsWithTheCurrentList() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a", title: "One"))

        var iterator = await manager.snapshots().makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first?.map(\.id), [itemID("a")])
        XCTAssertEqual(first?.first?.metadata.title, "One")
    }

    func testSlowSubscriberReceivesOnlyTheNewestList() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        var iterator = await manager.snapshots().makeAsyncIterator()
        _ = await iterator.next()

        try await manager.enqueue(makeRequest("a"))
        try await manager.enqueue(makeRequest("b"))
        try await manager.enqueue(makeRequest("c"))

        let latest = await iterator.next()
        XCTAssertEqual(latest?.map(\.id), [itemID("a"), itemID("b"), itemID("c")])
    }

    func testSnapshotDeliveryIsThrottledByTheClock() async throws {
        let harness = try Harness(snapshotInterval: 1)
        let manager = try await started(harness)
        var iterator = await manager.snapshots().makeAsyncIterator()
        _ = await iterator.next()

        try await manager.enqueue(makeRequest("a", expectedLength: 10))
        let queued = await iterator.next()
        XCTAssertEqual(queued?.first?.state, .queued)

        let reference = try await XCTUnwrapAsync(await harness.session.latestReference(for: itemID("a")))
        await manager.engine.ingest(.transfer(.progress(reference, bytesWritten: 5, expectedBytes: 10)))
        await eventually("flush scheduled") { await harness.clock.sleeperCount == 1 }
        let deadlines = await harness.clock.deadlines
        XCTAssertEqual(deadlines, [referenceDate.addingTimeInterval(1)])

        await harness.clock.advance(by: 1)
        let active = await iterator.next()
        XCTAssertEqual(active?.first?.state, .active)
        XCTAssertEqual(active?.first?.progress, 0.5)
    }

    func testEndingASubscriptionReleasesItWithoutAffectingTransfers() async throws {
        let harness = try Harness()
        let manager = try await started(harness)
        try await manager.enqueue(makeRequest("a"))
        let stream = await manager.snapshots()
        let reader = Task { for await _ in stream {} }
        await eventually("subscribed") { await manager.engine.subscriberCount == 1 }

        reader.cancel()

        await eventually("subscriber released") { await manager.engine.subscriberCount == 0 }
        let cancellations = await harness.session.cancellations
        let state = await manager.state(for: itemID("a"))
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertEqual(state, .queued)
    }
}
