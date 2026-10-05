//
//  DownloadListModelTests.swift
//  DownloadKitUITests
//
//  The model against a scripted controller: observation, coalescing, cancellation, commands,
//  confirmation, policy and lookup failures.
//

import XCTest
import Combine
import DownloadKit
@testable import DownloadKitUI

@MainActor
final class DownloadListModelTests: XCTestCase {
    private func observing(_ model: DownloadListModel, _ fake: FakeController) async throws -> Task<Void, Never> {
        let task = Task { await model.observe() }
        let subscribed = await eventually { await fake.liveSubscriptions == 1 }
        XCTAssertTrue(subscribed, "the model subscribed")
        return task
    }

    func testObservePublishesItemsAndBanner() async throws {
        let fake = FakeController()
        await fake.setStatus(.awaitingBacklog(deadline: Date()))
        let model = DownloadListModel(controller: fake)
        let task = try await observing(model, fake)

        await fake.send([snapshot("a", .active, bytes: 25, expected: 100, title: "A")])
        let received = await eventually { model.items.count == 1 }
        XCTAssertTrue(received)
        XCTAssertEqual(model.items.first?.indicator, .active(progress: 0.25))
        XCTAssertEqual(model.banner, .restoring)
        XCTAssertEqual(model.snapshot(for: id("a"))?.bytesWritten, 25)
        XCTAssertEqual(model.defaultPolicy, .default)
        XCTAssertTrue(model.isObserving)

        await fake.setStatus(.resolved)
        await fake.send([snapshot("a", .completed(at: Date()), bytes: 100, expected: 100, title: "A")])
        let cleared = await eventually { model.banner == nil }
        XCTAssertTrue(cleared)
        XCTAssertEqual(model.item(for: id("a"))?.indicator, .completed)
        task.cancel()
        await task.value
    }

    func testStatusChangeWithAnUnchangedListUpdatesTheBanner() async throws {
        let fake = FakeController()
        await fake.setStatus(.awaitingBacklog(deadline: Date()))
        let model = DownloadListModel(controller: fake)
        let task = try await observing(model, fake)
        let list = [snapshot("a", .queued, title: "A")]
        await fake.send(list)
        let restoring = await eventually { model.banner == .restoring }
        XCTAssertTrue(restoring)

        // The manager delivers the same list when only its reconciliation status moved.
        await fake.setStatus(.unresolved(items: [id("a")], reason: .deadlineExceeded))
        await fake.send(list)
        let unresolved = await eventually { model.banner != .restoring && model.banner != nil }
        XCTAssertTrue(unresolved, "a timeout without an item change replaces the spinner")

        await fake.setStatus(.resolved)
        await fake.send(list)
        let cleared = await eventually { model.banner == nil }
        XCTAssertTrue(cleared, "a quiet resolution clears the banner")
        task.cancel()
        await task.value
    }

    /// A policy read begun before a write may land after it; the write owns the value.
    func testAStalePolicyReadCannotOverwriteANewerWrite() async throws {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        await model.refreshDefaultPolicy()
        let staleRevision = model.policyRevision
        let stalePolicy = try XCTUnwrap(model.defaultPolicy)
        await model.setDefaultPolicy(.unmeteredIncludingLowData)
        let written = try XCTUnwrap(model.defaultPolicy)
        XCTAssertNotEqual(written, stalePolicy)
        // The pump's read that started before the write delivers now.
        model.receive([], status: .resolved, policy: stalePolicy, policyRevision: staleRevision)
        XCTAssertEqual(model.defaultPolicy, written, "a stale read must not overwrite the newer write")
        // A read begun after the write is applied as usual.
        model.receive([], status: .resolved, policy: stalePolicy, policyRevision: model.policyRevision)
        XCTAssertEqual(model.defaultPolicy, stalePolicy)
    }

    func testPolicySetOutsideTheModelIsPublished() async throws {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        let task = try await observing(model, fake)
        XCTAssertEqual(model.defaultPolicy, .default)

        let deferred = NetworkPolicy(allowsCellular: true, allowsExpensive: true, allowsConstrained: true, scheduling: .deferred)
        await fake.setPolicy(deferred)
        await fake.send([])
        let updated = await eventually { model.defaultPolicy == deferred }
        XCTAssertTrue(updated)
        XCTAssertEqual(model.policyChoice, .anyNetwork)
        task.cancel()
        await task.value
    }

    func testProgressBelowTheStepDoesNotPublish() async throws {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        var publications = 0
        let sink = model.objectWillChange.sink { publications += 1 }
        let task = try await observing(model, fake)
        let baseline = publications

        // 300 ticks of 1 byte on a 1 MB total: under one percent and under 64 KiB.
        for bytes in 1...300 {
            await fake.send([snapshot("a", .active, bytes: Int64(bytes), expected: 1_000_000)])
        }
        await fake.send([snapshot("a", .paused(resumable: true), bytes: 300, expected: 1_000_000)])
        let paused = await eventually { model.items.first.map { if case .paused = $0.indicator { return true } else { return false } } ?? false }
        XCTAssertTrue(paused)
        XCTAssertEqual(model.snapshots.first?.bytesWritten, 300, "the raw list is kept")
        XCTAssertLessThanOrEqual(publications - baseline, 2, "one publication for the first list, one for the pause")
        task.cancel()
        await task.value
        sink.cancel()
    }

    func testApplyingAnEqualListDoesNotPublish() {
        let model = DownloadListModel()
        var publications = 0
        let sink = model.objectWillChange.sink { publications += 1 }
        model.apply([])
        model.apply([snapshot("a", .queued)])
        model.apply([snapshot("a", .queued)])
        XCTAssertEqual(publications, 1)
        sink.cancel()
    }

    func testCancellingObservationEndsTheSubscriptionAndNothingElse() async throws {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        let task = try await observing(model, fake)
        task.cancel()
        await task.value

        XCTAssertFalse(model.isObserving)
        let ended = await eventually { await fake.terminations == 1 }
        XCTAssertTrue(ended, "the subscription ended with the task")
        let live = await fake.liveSubscriptions
        XCTAssertEqual(live, 0)
        let calls = await fake.calls
        XCTAssertEqual(Set(calls), ["defaultPolicy", "snapshots"], "observation sends no command")

        // The controller still works for a later observation.
        let again = try await observing(model, fake)
        again.cancel()
        await again.value
        let subscriptions = await fake.subscriptions
        XCTAssertEqual(subscriptions, 2)
    }

    func testConcurrentObservationsAreIndependent() async throws {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        let first = Task { await model.observe() }
        let second = Task { await model.observe() }
        let both = await eventually { await fake.liveSubscriptions == 2 }
        XCTAssertTrue(both)
        first.cancel()
        await first.value
        XCTAssertTrue(model.isObserving)
        second.cancel()
        await second.value
        XCTAssertFalse(model.isObserving)
    }

    func testStreamEndEndsObservation() async throws {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        let task = try await observing(model, fake)
        await fake.finishAll()
        await task.value
        XCTAssertFalse(model.isObserving)
    }

    func testModelIsReleasedOnceObservationEnds() async throws {
        let fake = FakeController()
        var model: DownloadListModel? = DownloadListModel(controller: fake)
        weak let weakModel = model
        let task = try await observing(model!, fake)
        task.cancel()
        await task.value
        model = nil
        XCTAssertNil(weakModel, "nothing in the observation keeps the model alive")
        let ended = await eventually { await fake.liveSubscriptions == 0 }
        XCTAssertTrue(ended)
    }

    func testCommandsForwardAndFailuresKeepOnlyAReason() async {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        await model.perform(.pause, on: id("a"))
        await model.perform(.resume, on: id("a"))
        await model.perform(.cancel, on: id("a"))
        await model.perform(.retry, on: id("a"))
        var calls = await fake.calls
        XCTAssertEqual(calls, ["pause a", "resume a", "cancel a", "retry a"])
        XCTAssertNil(model.lastFailure)

        await fake.setCommandError(DownloadError.itemBeingRemoved(id("a")))
        await model.perform(.retry, on: id("a"))
        XCTAssertEqual(model.lastFailure?.reason, .itemBeingRemoved)
        XCTAssertEqual(model.lastFailure?.action, .retry)
        XCTAssertEqual(model.lastFailure?.itemID, id("a"))
        XCTAssertTrue(model.busyItems.isEmpty)
        calls = await fake.calls
        XCTAssertEqual(calls.last, "retry a")
    }

    func testBurstOfCommandsForOneItemSendsOne() async {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        await fake.setHoldCommands(true)
        let first = Task { await model.perform(.pause, on: id("a")) }
        let held = await eventually { await fake.heldCount == 1 }
        XCTAssertTrue(held)
        XCTAssertEqual(model.busyItems, [id("a")])
        await model.perform(.pause, on: id("a"))
        await model.perform(.cancel, on: id("a"))
        let other = Task { await model.perform(.pause, on: id("b")) }
        let otherHeld = await eventually { await fake.heldCount == 2 }
        XCTAssertTrue(otherHeld, "another item is not blocked")
        await fake.releaseHeld()
        await first.value
        await other.value
        let calls = await fake.calls
        XCTAssertEqual(calls, ["pause a", "pause b"])
        XCTAssertTrue(model.busyItems.isEmpty)
    }

    func testRemovalNeedsConfirmationAndNamesExplicitMembers() async {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        model.apply([
            snapshot("a", .completed(at: Date()), title: "Alpha", group: "G"),
            snapshot("b", .completed(at: Date()), group: "G"),
            snapshot("c", .completed(at: Date())),
        ])

        await model.perform(.remove, on: id("a"))
        var calls = await fake.calls
        XCTAssertTrue(calls.isEmpty, "remove only asks")
        XCTAssertEqual(model.pendingRemoval?.ids, [id("a")])
        XCTAssertEqual(model.pendingRemoval?.title, "Alpha")
        model.cancelRemoval()
        XCTAssertNil(model.pendingRemoval)
        await model.confirmRemoval()
        calls = await fake.calls
        XCTAssertTrue(calls.isEmpty, "a cancelled request removes nothing")

        XCTAssertEqual(model.members(of: "G"), [id("a"), id("b")])
        model.requestRemoval(of: model.members(of: "G"), title: "G")
        await model.confirmRemoval()
        calls = await fake.calls
        XCTAssertEqual(calls, ["remove a,b"])
        XCTAssertNil(model.pendingRemoval)

        model.requestRemoval(of: [], title: nil)
        XCTAssertNil(model.pendingRemoval)
    }

    func testDefaultPolicyLoadsAndKeepsScheduling() async {
        let fake = FakeController()
        await fake.setPolicy(NetworkPolicy(allowsCellular: false, allowsExpensive: false, allowsConstrained: false, scheduling: .deferred))
        let model = DownloadListModel(controller: fake)
        XCTAssertNil(model.policyChoice)
        await model.refreshDefaultPolicy()
        XCTAssertEqual(model.policyChoice, .unmeteredOnly)

        await model.setDefaultPolicy(.anyNetwork)
        let stored = await fake.policy
        XCTAssertEqual(stored, NetworkPolicyChoice.anyNetwork.policy(scheduling: .deferred))
        XCTAssertEqual(model.policyChoice, .anyNetwork)

        await fake.setCommandError(DownloadError.persistenceFailed)
        await model.setDefaultPolicy(.unmeteredOnly)
        XCTAssertEqual(model.policyChoice, .anyNetwork, "a refused change is not shown as applied")
        XCTAssertEqual(model.lastFailure?.reason, .persistenceFailed)

        await fake.setPolicy(NetworkPolicy(allowsCellular: true, allowsExpensive: false, allowsConstrained: false))
        await model.refreshDefaultPolicy()
        XCTAssertNil(model.policyChoice, "a custom policy is not mislabelled")
    }

    func testStartFailureBannerWinsUntilCleared() async {
        let fake = FakeController()
        await fake.setStatus(.awaitingBacklog(deadline: Date()))
        let model = DownloadListModel(controller: fake)
        model.reportStartFailure(DownloadError.storageUnavailable)
        XCTAssertEqual(model.banner, .startFailed(.storageUnavailable))
        await model.refreshStatus()
        XCTAssertEqual(model.banner, .startFailed(.storageUnavailable))
        model.clearStartFailure()
        await model.refreshStatus()
        XCTAssertEqual(model.banner, .restoring)
        await fake.setStatus(.unresolved(items: [id("a")], reason: .sessionStorageFailed))
        await model.refreshStatus()
        XCTAssertEqual(model.banner, .storageFailed(count: 1))
    }

    func testLocalFileLookupFailuresAreMappedAndHoldNoLease() async {
        let fake = FakeController()
        let model = DownloadListModel(controller: fake)
        await fake.setLocal(.unavailable(.missing))
        var result = await model.openLocalFile(for: id("a"))
        XCTAssertEqual(result, .unavailable(.missing))
        await fake.setLocal(.unavailable(.inProgress))
        result = await model.openLocalFile(for: id("a"))
        XCTAssertEqual(result, .unavailable(.inProgress))
        await fake.setLocal(.unavailable(.notDownloaded), error: DownloadError.fileAccessFailed(id("a")))
        result = await model.openLocalFile(for: id("a"))
        XCTAssertEqual(result, .accessFailed)
        await fake.setLocal(.unavailable(.notDownloaded), error: DownloadError.notStarted)
        result = await model.openLocalFile(for: id("a"))
        XCTAssertEqual(result, .failed(.notStarted))
        XCTAssertTrue(model.openLeases.isEmpty)
        await model.endAllAccess()
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("endAccess") })
    }

    func testModelWithoutControllerOnlyPresents() async {
        let model = DownloadListModel()
        await model.observe()
        XCTAssertFalse(model.isObserving)
        model.apply([snapshot("a", .failed(DownloadFailure(kind: .integrity)))])
        XCTAssertEqual(model.items.first?.indicator, .failed(DownloadFailure(kind: .integrity)))
        await model.perform(.retry, on: id("a"))
        XCTAssertEqual(model.lastFailure?.reason, .notStarted)
        let local = await model.openLocalFile(for: id("a"))
        XCTAssertEqual(local, .failed(.notStarted))
    }
}
