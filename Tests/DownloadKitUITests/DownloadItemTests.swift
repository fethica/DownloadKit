//
//  DownloadItemTests.swift
//  DownloadKitUITests
//
//  State mapping, quantisation, grouping and the small value types.
//

import XCTest
import DownloadKit
@testable import DownloadKitUI

final class DownloadItemTests: XCTestCase {
    func testEveryStateMapsToItsIndicatorAndActions() {
        let failure = DownloadFailure(kind: .network)
        let retryAt = Date(timeIntervalSince1970: 100)
        let cases: [(DownloadState, DownloadIndicator, [DownloadAction], DownloadAction?)] = [
            (.notDownloaded, .notDownloaded, [], nil),
            (.queued, .queued, [.pause, .cancel, .remove], .pause),
            (.active, .active(progress: 0.5), [.pause, .cancel, .remove], .pause),
            (.waiting(.networkPolicy), .waiting(.networkPolicy, progress: 0.5), [.pause, .cancel, .remove], .pause),
            (.waiting(.connectivity), .waiting(.connectivity, progress: 0.5), [.pause, .cancel, .remove], .pause),
            (.waiting(.retryScheduled(at: retryAt)), .waiting(.retryScheduled(at: retryAt), progress: 0.5), [.retry, .pause, .cancel, .remove], .retry),
            (.waiting(.system), .waiting(.system, progress: 0.5), [.pause, .cancel, .remove], .pause),
            (.waiting(.unknown), .waiting(.unknown, progress: 0.5), [.pause, .cancel, .remove], .pause),
            (.paused(resumable: true), .paused(resumable: true, progress: 0.5), [.resume, .cancel, .remove], .resume),
            (.paused(resumable: false), .paused(resumable: false, progress: 0.5), [.resume, .cancel, .remove], .resume),
            (.failed(failure), .failed(failure), [.retry, .remove], .retry),
            (.failed(DownloadFailure(kind: .cancelled)), .failed(DownloadFailure(kind: .cancelled)), [.retry, .remove], .retry),
            (.completed(at: Date()), .completed, [.remove], nil),
            (.removing, .removing, [], nil),
            (.missing, .missing, [.retry, .remove], .retry),
        ]
        for (state, indicator, actions, primary) in cases {
            let item = DownloadItem(snapshot: snapshot("a", state, bytes: 50, expected: 100))
            XCTAssertEqual(item.indicator, indicator, "\(state)")
            XCTAssertEqual(item.indicator.actions, actions, "\(state)")
            XCTAssertEqual(item.indicator.primaryAction, primary, "\(state)")
        }
    }

    func testPausedIsNeverShownAsActive() {
        let item = DownloadItem(snapshot: snapshot("a", .paused(resumable: true), bytes: 10, expected: 100))
        if case .active = item.indicator { XCTFail("paused shown as active") }
        XCTAssertFalse(item.indicator.actions.contains(.pause))
    }

    func testProgressIsQuantisedAndIndeterminateWithoutTotal() {
        let determinate = DownloadItem(snapshot: snapshot("a", .active, bytes: 4_299, expected: 10_000))
        XCTAssertEqual(determinate.indicator, .active(progress: 0.42))
        let indeterminate = DownloadItem(snapshot: snapshot("a", .active, bytes: 4_299, expected: nil))
        XCTAssertEqual(indeterminate.indicator, .active(progress: nil))
        XCTAssertNil(indeterminate.indicator.progress)
        let zeroTotal = DownloadItem(snapshot: snapshot("a", .active, bytes: 1, expected: 0))
        XCTAssertEqual(zeroTotal.indicator, .active(progress: nil))
        let done = DownloadItem(snapshot: snapshot("a", .completed(at: Date()), bytes: 10_000, expected: 10_000))
        XCTAssertEqual(done.indicator.progress, 1)
        let finer = DownloadItem(snapshot: snapshot("a", .active, bytes: 4_299, expected: 10_000), progressStep: 0.1)
        XCTAssertEqual(finer.indicator.progress ?? 0, 0.4, accuracy: 1e-9)
    }

    func testTitleFallsBackToIdentifierAndBytesRoundDown() {
        let untitled = DownloadItem(snapshot: snapshot("episode-7", .active, bytes: 200_000, title: "  "))
        XCTAssertEqual(untitled.title, "episode-7")
        XCTAssertEqual(untitled.receivedBytes, 196_608, "rounded down to 64 KiB")
        let titled = DownloadItem(snapshot: snapshot("episode-7", .active, bytes: 10, expected: 10_000_000, title: "Seven"))
        XCTAssertEqual(titled.title, "Seven")
        XCTAssertEqual(titled.receivedBytes, 0, "below one percent of the total")
        let complete = DownloadItem(snapshot: snapshot("a", .completed(at: Date()), bytes: 1_234, expected: 1_234))
        XCTAssertEqual(complete.receivedBytes, 1_234, "a complete count is exact")
    }

    func testSectionsGroupInFirstAppearanceOrder() {
        let items = [
            snapshot("a", .queued, group: "B"),
            snapshot("b", .queued),
            snapshot("c", .queued, group: "A"),
            snapshot("d", .queued, group: "B"),
        ].map { DownloadItem(snapshot: $0) }
        let sections = DownloadSection.grouping(items)
        XCTAssertEqual(sections.map(\.group), ["B", nil, "A"])
        XCTAssertEqual(sections[0].items.map(\.id.rawValue), ["a", "d"])
        XCTAssertEqual(Set(sections.map(\.id)).count, 3)
    }

    func testBannerFollowsReconciliationStatus() {
        XCTAssertNil(DownloadBanner(status: .notStarted))
        XCTAssertNil(DownloadBanner(status: .resolved))
        XCTAssertEqual(DownloadBanner(status: .awaitingBacklog(deadline: Date())), .restoring)
        XCTAssertEqual(DownloadBanner(status: .unresolved(items: [id("a"), id("b")], reason: .deadlineExceeded)), .unresolved(count: 2))
        XCTAssertEqual(DownloadBanner(status: .unresolved(items: [id("a")], reason: .sessionEnded)), .unresolved(count: 1))
        XCTAssertEqual(DownloadBanner(status: .unresolved(items: [id("a")], reason: .sessionStorageFailed)), .storageFailed(count: 1))
    }

    func testPolicyChoicesRoundTripAndKeepScheduling() {
        for choice in NetworkPolicyChoice.allCases {
            XCTAssertEqual(NetworkPolicyChoice(policy: choice.policy()), choice)
            XCTAssertEqual(NetworkPolicyChoice(policy: choice.policy(scheduling: .deferred)), choice)
            XCTAssertEqual(choice.policy(scheduling: .deferred).scheduling, .deferred)
        }
        XCTAssertEqual(NetworkPolicyChoice(policy: .default), .unmeteredOnly)
        XCTAssertEqual(NetworkPolicyChoice(policy: .anyNetwork), .anyNetwork)
        XCTAssertNil(NetworkPolicyChoice(policy: NetworkPolicy(allowsCellular: true, allowsExpensive: false, allowsConstrained: false)))
        XCTAssertFalse(NetworkPolicyChoice.unmeteredIncludingLowData.policy().allowsCellular)
        XCTAssertTrue(NetworkPolicyChoice.unmeteredIncludingLowData.policy().allowsConstrained)
    }

    func testCommandFailureReasonsKeepNoPayload() {
        let cases: [(any Error, DownloadCommandFailure.Reason)] = [
            (DownloadError.notStarted, .notStarted),
            (DownloadError.itemBeingRemoved(id("secret-id")), .itemBeingRemoved),
            (DownloadError.unknownItem(id("x")), .unknownItem),
            (DownloadError.conflictingRequest(id("x")), .conflictingRequest),
            (DownloadError.persistenceFailed, .persistenceFailed),
            (DownloadError.reconciliationUnresolved, .reconciliationUnresolved),
            (DownloadError.storageUnavailable, .storageUnavailable),
            (DownloadError.corruptIndex, .unsupportedIndex),
            (DownloadError.unsupportedSchema(found: 9, supported: 2), .unsupportedIndex),
            (DownloadError.fileAccessFailed(id("x")), .fileAccessFailed),
            (DownloadError.ownerAlreadyActive, .anotherOwner),
            (DownloadError.invalidRelativePath("/private/var/mobile/x"), .other),
            (URLError(.notConnectedToInternet), .other),
        ]
        for (error, reason) in cases {
            XCTAssertEqual(DownloadCommandFailure.Reason(error), reason, "\(error)")
        }
    }
}
