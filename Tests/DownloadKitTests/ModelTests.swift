//
//  ModelTests.swift
//  DownloadKitTests
//
//  Validation rules, classification, backoff, policy evaluation and the persisted record shape.
//

import XCTest
@testable import DownloadKit

final class ModelTests: XCTestCase {

    func testDownloadIDRules() throws {
        XCTAssertNoThrow(try DownloadID("episode/42?lang=en"))
        XCTAssertThrowsError(try DownloadID(""))
        XCTAssertThrowsError(try DownloadID("line\nbreak"))
        XCTAssertThrowsError(try DownloadID(String(repeating: "x", count: DownloadID.maximumLength + 1)))
    }

    func testDownloadIDDecodingRevalidates() {
        let data = Data("\"\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadID.self, from: data))
    }

    func testStorageScopeRequiresASafeNamespace() {
        XCTAssertNoThrow(try StorageScope(namespace: "com.example.player-downloads_v1"))
        for bad in ["", ".hidden", "a/b", "..", "with space", String(repeating: "n", count: 65)] {
            XCTAssertThrowsError(try StorageScope(namespace: bad), bad) { error in
                XCTAssertEqual(error as? DownloadError, .invalidNamespace(bad))
            }
        }
    }

    func testSessionIdentifierIsRequired() {
        let dependencies = DownloadDependencies(
            transport: FakeTransferSessionFactory(session: FakeTransferSession(identifier: "x")),
            makeIndexStore: { _ in InMemoryIndexStore() },
            fileSystem: FakeFileSystem()
        )
        XCTAssertThrowsError(try DownloadConfiguration(storageScope: StorageScope(namespace: "n"), sessionIdentifier: "", dependencies: dependencies)) { error in
            XCTAssertEqual(error as? DownloadError, .invalidSessionIdentifier(""))
        }
    }

    func testRelativePathRejectsEscapes() throws {
        XCTAssertNoThrow(try RelativePath("media/item-1"))
        for bad in ["", "/media/item-1", "~/x", "media/../index", "./media", "media//x", "media\\x", "media/"] {
            XCTAssertThrowsError(try RelativePath(bad), bad)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(RelativePath.self, from: Data("\"../escape\"".utf8)))
        XCTAssertEqual(RelativePath.media(generation: 9).rawValue, "media/item-9")
        XCTAssertTrue(RelativePath.staging().rawValue.hasPrefix("staging/"))
    }

    func testDefaultPolicyIsUnmeteredOnly() {
        XCTAssertEqual(NetworkPolicy.default, NetworkPolicy(allowsCellular: false, allowsExpensive: false, allowsConstrained: false, scheduling: .userInitiated))
    }

    func testPolicyEvaluationGivesHonestReasons() {
        let unmetered = NetworkPolicy.unmeteredOnly
        XCTAssertEqual(unmetered.evaluate(NetworkPathStatus(isSatisfied: false)), .waiting(.connectivity))
        XCTAssertEqual(unmetered.evaluate(NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true)), .waiting(.networkPolicy))
        XCTAssertEqual(unmetered.evaluate(NetworkPathStatus(isSatisfied: true, isExpensive: true)), .waiting(.networkPolicy))
        XCTAssertEqual(unmetered.evaluate(NetworkPathStatus(isSatisfied: true, isConstrained: true)), .waiting(.networkPolicy))
        XCTAssertEqual(unmetered.evaluate(NetworkPathStatus(isSatisfied: true)), .allowed)
        XCTAssertEqual(NetworkPolicy.anyNetwork.evaluate(NetworkPathStatus(isSatisfied: true, isExpensive: true, isConstrained: true, usesCellular: true)), .allowed)
        let cellularButNotExpensive = NetworkPolicy(allowsCellular: true, allowsExpensive: false, allowsConstrained: true)
        XCTAssertEqual(cellularButNotExpensive.evaluate(NetworkPathStatus(isSatisfied: true, isExpensive: true, usesCellular: true)), .waiting(.networkPolicy))
    }

    func testFailureClassification() {
        XCTAssertEqual(TransferFailure.network(code: -1001).classification, .networkTransient)
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(TransferFailure.http(status: status, retryAfter: nil).classification, .networkTransient, "\(status)")
        }
        XCTAssertEqual(TransferFailure.http(status: 401, retryAfter: nil).classification, .authentication)
        XCTAssertEqual(TransferFailure.http(status: 403, retryAfter: nil).classification, .authentication)
        XCTAssertEqual(TransferFailure.http(status: 404, retryAfter: nil).classification, .permanentHTTP)
        XCTAssertEqual(TransferFailure.http(status: 416, retryAfter: nil).classification, .permanentHTTP)
        XCTAssertEqual(TransferFailure.http(status: 200, retryAfter: nil).classification, .invalidResponse)
        XCTAssertEqual(TransferFailure.storage(.diskFull).classification, .storage)
        XCTAssertEqual(TransferFailure.integrity.classification, .integrity)
        XCTAssertEqual(TransferFailure.cancelled.classification, .cancelled)
        XCTAssertEqual(TransferFailure.policyBlocked.classification, .policyWait)
    }

    func testFailureKeysAreStable() {
        XCTAssertEqual(DownloadFailure.Kind.allCases.map(\.rawValue), [
            "unknown", "network", "http", "storage_full", "storage", "file_protection",
            "integrity", "unauthorized", "invalid_response", "cancelled",
        ])
    }

    func testBackoffIsExponentialBoundedAndJittered() {
        let policy = RetryPolicy(baseDelay: 2, maximumDelay: 10)
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 1, retryAfter: nil), 2)
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 0, retryAfter: nil), 1)
        XCTAssertEqual(policy.delay(forRetry: 2, jitter: 1, retryAfter: nil), 8)
        XCTAssertEqual(policy.delay(forRetry: 5, jitter: 1, retryAfter: nil), 10)
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 7, retryAfter: nil), 2, "jitter is clamped")
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 1, retryAfter: 30), 30)
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 1, retryAfter: 1_000_000), policy.maximumRetryAfter)
        XCTAssertEqual(RetryPolicy.default.maximumAutomaticRetries, 3)
    }

    func testRetryAfterNeverShortensTheExponentialDelay() {
        let policy = RetryPolicy(baseDelay: 100, maximumDelay: 100, maximumRetryAfter: 10)
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 1, retryAfter: 1), 100)
        XCTAssertEqual(policy.delay(forRetry: 0, jitter: 1, retryAfter: 50), 100, "a capped hint below the backoff changes nothing")
        let generous = RetryPolicy(baseDelay: 2, maximumDelay: 10, maximumRetryAfter: 60)
        XCTAssertEqual(generous.delay(forRetry: 0, jitter: 1, retryAfter: 45), 45)
        XCTAssertEqual(generous.delay(forRetry: 0, jitter: 1, retryAfter: 600), 60)
    }

    func testIndexRecordRoundTripsThroughJSONWithRelativePathsOnly() throws {
        var machine = DownloadStateMachine.fresh()
        let generation = try machine.enqueueAndBind("a", request: makeRequest("a", expectedLength: 10, policy: .anyNetwork))
        _ = machine.send(.finished(reference("a", generation: generation), captured: path("staging/a"), bytes: 10, validators: ResponseValidators(entityTag: "\"e\"", lastModified: "Mon")))
        let contents = IndexContents(nextGeneration: machine.nextGeneration, defaultPolicy: .anyNetwork, records: Array(machine.records.values))

        let data = try JSONEncoder().encode(contents)
        let decoded = try JSONDecoder().decode(IndexContents.self, from: data)

        XCTAssertEqual(decoded, contents)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"stagingPath\":\"staging\\/a\""))
        XCTAssertFalse(json.contains("file:"), "no absolute file URLs are stored")
    }

    func testChangeSetApplicationIsAtomicAndStampsTheSchema() throws {
        var machine = DownloadStateMachine.fresh()
        try machine.enqueueAndBind("a")
        try machine.enqueueAndBind("b")
        let start = IndexContents(schemaVersion: 1, nextGeneration: 3, records: Array(machine.records.values))

        let next = IndexChangeSet(deletions: [itemID("a")], nextGeneration: 2, defaultPolicy: .anyNetwork).applied(to: start)

        XCTAssertEqual(next.records.map(\.id), [itemID("b")])
        XCTAssertEqual(next.nextGeneration, 3, "the generation counter never decreases")
        XCTAssertEqual(next.defaultPolicy, .anyNetwork)
        XCTAssertEqual(next.schemaVersion, IndexSchema.currentVersion)
    }

    func testSnapshotProgressOnlyWhenMeaningful() {
        func snapshot(_ state: DownloadState, bytes: Int64, expected: Int64?) -> DownloadSnapshot {
            DownloadSnapshot(id: itemID("a"), revision: .unversioned, metadata: DownloadMetadata(), state: state, bytesWritten: bytes, expectedBytes: expected, automaticRetryCount: 0, retryAt: nil, updatedAt: referenceDate)
        }
        XCTAssertEqual(snapshot(.active, bytes: 5, expected: 10).progress, 0.5)
        XCTAssertNil(snapshot(.active, bytes: 5, expected: nil).progress)
        XCTAssertNil(snapshot(.active, bytes: 5, expected: 0).progress)
        XCTAssertEqual(snapshot(.active, bytes: 50, expected: 10).progress, 1)
        XCTAssertNil(snapshot(.failed(DownloadFailure(kind: .network)), bytes: 5, expected: 10).progress)
        XCTAssertEqual(snapshot(.completed(at: referenceDate), bytes: 10, expected: 10).progress, 1)
    }
}
