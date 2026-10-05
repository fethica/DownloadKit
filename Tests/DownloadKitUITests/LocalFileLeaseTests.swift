//
//  LocalFileLeaseTests.swift
//  DownloadKitUITests
//
//  The model's lease handling against a real manager on the production adapters (foreground
//  URLSession with a URLProtocol fixture, SQLite index, local file system) in a temporary
//  directory. Leases cannot be made outside the core, so this is the only honest way to test
//  them from here. Playback ownership runs through a wrapper that can hold each lookup's result
//  after the manager issued its lease, so overlapping Play and Stop commands interleave in a
//  chosen order.
//

import XCTest
import DownloadKit
@testable import DownloadKitUI

/// Counts requests and serves a small WAV-like body on `ui.fixture.test`.
final class LeaseFixtureProtocol: URLProtocol {
    static let host = "ui.fixture.test"
    static let body: Data = {
        var data = Data("RIFF".utf8)
        data.append(Data((0..<8_188).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }))
        return data
    }()
    private static let counter = RequestCounter()
    static var requests: Int { counter.value }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client, let url = request.url else { return }
        Self.counter.increment()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "audio/wav", "Content-Length": "\(Self.body.count)", "ETag": "\"v1\"",
        ])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Self.body)
        client.urlProtocolDidFinishLoading(self)
    }
}

/// Forwards to a real manager; while holding, each `localFile` result (and the lease the manager
/// already issued for it) is kept back until the test releases it.
actor GatedController: DownloadControlling {
    let manager: DownloadManager
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ manager: DownloadManager) { self.manager = manager }

    var heldCount: Int { held.count }
    func setHolding(_ holding: Bool) { self.holding = holding }

    /// Releases the held lookup at `index` (in arrival order).
    func release(_ index: Int) {
        held.remove(at: index).resume()
    }

    func snapshots() async -> DownloadSnapshotStream { await manager.snapshots() }
    func pause(_ id: DownloadID) async throws { try await manager.pause(id) }
    func resume(_ id: DownloadID) async throws { try await manager.resume(id) }
    func cancel(_ id: DownloadID) async throws { try await manager.cancel(id) }
    func retry(_ id: DownloadID) async throws { try await manager.retry(id) }
    func remove(_ ids: [DownloadID]) async throws { try await manager.remove(ids) }
    func defaultPolicy() async -> NetworkPolicy { await manager.defaultPolicy() }
    func setDefaultPolicy(_ policy: NetworkPolicy) async throws { try await manager.setDefaultPolicy(policy) }
    func reconciliationStatus() async -> ReconciliationStatus { await manager.reconciliationStatus() }
    func endAccess(_ lease: LocalFileLease) async { await manager.endAccess(lease) }

    func localFile(for id: DownloadID) async throws -> LocalFileResult {
        let result = try await manager.localFile(for: id)
        if holding { await withCheckedContinuation { held.append($0) } }
        return result
    }
}

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
final class LocalFileLeaseTests: XCTestCase {
    private var directory: URL!
    private var manager: DownloadManager!
    private var transport: URLSessionTransport!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-lease-\(UUID().uuidString.lowercased())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transport = URLSessionTransport(options: .init(configure: { configuration in
            configuration.protocolClasses = [LeaseFixtureProtocol.self]
        }))
        let configuration = try DownloadConfiguration(
            storageScope: StorageScope(namespace: "ui-tests"),
            sessionIdentifier: "ui-tests-\(UUID().uuidString.lowercased())",
            snapshotInterval: 0.01,
            dependencies: DownloadDependencies(
                transport: transport,
                makeIndexStore: SQLiteIndexStore.opener(),
                fileSystem: LocalFileSystem(applicationSupportDirectory: directory, fileProtection: nil)
            )
        )
        manager = DownloadManager(configuration: configuration)
        try await manager.start()
    }

    override func tearDown() async throws {
        await manager.detach()
        await transport.invalidate(cancellingTasks: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private func downloadCompleted(_ raw: String) async throws -> DownloadID {
        let itemID = try DownloadID(raw)
        try await manager.enqueue(DownloadRequest(
            id: itemID,
            url: URL(string: "https://\(LeaseFixtureProtocol.host)/\(raw).wav")!,
            expectedLength: Int64(LeaseFixtureProtocol.body.count),
            metadata: DownloadMetadata(title: raw)
        ))
        let manager = manager!
        let done = await eventually(10) {
            if case .completed = await manager.state(for: itemID) { return true }
            return false
        }
        XCTAssertTrue(done, "the fixture download completed")
        return itemID
    }

    func testLeaseKeepsTheFileThroughRemovalUntilEnded() async throws {
        let itemID = try await downloadCompleted("tone")
        let model = DownloadListModel(controller: manager)

        guard case .available(let lease) = await model.openLocalFile(for: itemID) else {
            return XCTFail("a completed file is available")
        }
        XCTAssertEqual(model.openLeases, [lease])
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        XCTAssertEqual(try Data(contentsOf: lease.url), LeaseFixtureProtocol.body)

        model.requestRemoval(of: [itemID], title: "tone")
        await model.confirmRemoval()
        let removing = await manager.state(for: itemID)
        XCTAssertEqual(removing, .removing, "a leased item waits")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path), "the leased file stays")

        await model.endAccess(lease)
        XCTAssertTrue(model.openLeases.isEmpty)
        let manager = manager!
        let gone = await eventually { await manager.state(for: itemID) == .notDownloaded }
        XCTAssertTrue(gone, "removal finishes once the lease ended")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        await model.endAccess(lease)  // ending twice is safe
    }

    func testEndAllAccessEndsEveryLeaseOfTheModel() async throws {
        let itemID = try await downloadCompleted("chime")
        let model = DownloadListModel(controller: manager)
        guard case .available(let first) = await model.openLocalFile(for: itemID),
              case .available(let second) = await model.openLocalFile(for: itemID) else {
            return XCTFail("a completed file is available")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.openLeases.count, 2)
        try await manager.remove(itemID)
        await model.endAllAccess()
        XCTAssertTrue(model.openLeases.isEmpty)
        let manager = manager!
        let gone = await eventually { await manager.state(for: itemID) == .notDownloaded }
        XCTAssertTrue(gone)
    }

    func testLookupOfAnItemThatIsNotDownloadedNeverFetches() async throws {
        let model = DownloadListModel(controller: manager)
        let before = LeaseFixtureProtocol.requests
        let result = await model.openLocalFile(for: try DownloadID("never-enqueued"))
        XCTAssertEqual(result, .unavailable(.notDownloaded))
        XCTAssertEqual(LeaseFixtureProtocol.requests, before, "lookup sends no request")
        XCTAssertTrue(model.openLeases.isEmpty)
    }

    func testObservingTheRealManagerAndLeavingKeepsItRunning() async throws {
        let model = DownloadListModel(controller: manager)
        let task = Task { await model.observe() }
        let itemID = try await downloadCompleted("bell")
        let seen = await eventually { model.item(for: itemID)?.indicator == .completed }
        XCTAssertTrue(seen)
        task.cancel()
        await task.value
        XCTAssertFalse(model.isObserving)
        // The manager still accepts commands and serves files after the view went away.
        let local = try await manager.localFile(for: itemID)
        guard case .available(let lease) = local else { return XCTFail("still available") }
        await manager.endAccess(lease)
        try await manager.remove(itemID)
    }

    // MARK: Playback ownership

    private func waitForHeld(_ gate: GatedController, _ count: Int) async {
        let reached = await eventually { await gate.heldCount == count }
        XCTAssertTrue(reached, "\(count) lookups held")
    }

    private func assertRemovalFinishes(_ ids: [DownloadID], file: StaticString = #filePath, line: UInt = #line) async throws {
        try await manager.remove(ids)
        let manager = manager!
        let gone = await eventually {
            for id in ids where await manager.state(for: id) != .notDownloaded { return false }
            return true
        }
        XCTAssertTrue(gone, "the removal finished: no lease was left behind", file: file, line: line)
    }

    /// Two Play taps whose lookups overlap, the older result arriving last, then Stop: the
    /// older lease is ended when it arrives, Stop ends the other, and removal proceeds.
    func testOverlappingPlayRequestsLeaveOneLeaseAndStopEndsIt() async throws {
        let tone = try await downloadCompleted("tone")
        let chime = try await downloadCompleted("chime")
        let gate = GatedController(manager)
        let model = DownloadListModel(controller: gate)
        await gate.setHolding(true)

        let first = Task { await model.beginPlayback(of: tone) }
        await waitForHeld(gate, 1)
        let second = Task { await model.beginPlayback(of: chime) }
        await waitForHeld(gate, 2)

        await gate.release(1)
        let newest = await second.value
        guard case .available(let lease) = newest else { return XCTFail("the newest request plays, got \(String(describing: newest))") }
        XCTAssertEqual(lease.id, chime)
        XCTAssertEqual(model.playbackLease, lease)

        await gate.release(0)
        let overtaken = await first.value
        XCTAssertNil(overtaken, "the overtaken request does nothing")
        XCTAssertEqual(model.openLeases, [lease], "the overtaken lease was ended on arrival")
        XCTAssertEqual(model.playbackLease, lease)

        await model.endPlayback()
        await model.endPlayback()  // idempotent
        XCTAssertNil(model.playbackLease)
        XCTAssertTrue(model.openLeases.isEmpty, "no lease is left")
        try await assertRemovalFinishes([tone, chime])
    }

    /// Play, then Stop while the lookup is still in flight: the late result is not installed.
    func testStopDuringALookupEndsTheLateLease() async throws {
        let tone = try await downloadCompleted("tone")
        let gate = GatedController(manager)
        let model = DownloadListModel(controller: gate)
        await gate.setHolding(true)

        let play = Task { await model.beginPlayback(of: tone) }
        await waitForHeld(gate, 1)
        await model.endPlayback()
        await gate.release(0)
        let result = await play.value
        XCTAssertNil(result)
        XCTAssertNil(model.playbackLease)
        XCTAssertTrue(model.openLeases.isEmpty)
        try await assertRemovalFinishes([tone])
    }

    /// Changing the played item ends the previous item's lease before the new lookup.
    func testPlayingAnotherItemEndsThePreviousLease() async throws {
        let tone = try await downloadCompleted("tone")
        let chime = try await downloadCompleted("chime")
        let model = DownloadListModel(controller: manager)

        guard case .available(let firstLease) = await model.beginPlayback(of: tone) else { return XCTFail("tone plays") }
        guard case .available(let secondLease) = await model.beginPlayback(of: chime) else { return XCTFail("chime plays") }
        XCTAssertEqual(model.openLeases, [secondLease], "the first item's lease ended on the change")
        XCTAssertNotEqual(firstLease, secondLease)
        try await assertRemovalFinishes([tone])

        // Replaying the same item also replaces, never adds, its lease.
        guard case .available(let again) = await model.beginPlayback(of: chime) else { return XCTFail("chime plays again") }
        XCTAssertEqual(model.openLeases, [again])
        await model.endAllAccess()
        XCTAssertNil(model.playbackLease)
        try await assertRemovalFinishes([chime])
    }

    /// A burst of taps on two items, started before any lookup returns, then Stop.
    func testBurstOfPlayTapsLeavesNoLeaseAfterStop() async throws {
        let tone = try await downloadCompleted("tone")
        let chime = try await downloadCompleted("chime")
        let model = DownloadListModel(controller: manager)
        let taps = (0..<8).map { index in Task { await model.beginPlayback(of: index.isMultiple(of: 2) ? tone : chime) } }
        var winners = 0
        for tap in taps where await tap.value != nil { winners += 1 }
        XCTAssertGreaterThanOrEqual(winners, 1)
        XCTAssertEqual(model.openLeases.count, 1, "one playback lease at a time")
        await model.endPlayback()
        XCTAssertTrue(model.openLeases.isEmpty)
        try await assertRemovalFinishes([tone, chime])
    }

    /// Confirming the removal of the playing item ends the playback lease so the removal can
    /// finish; an unrelated removal leaves playback alone.
    func testRemovingThePlayingItemEndsItsPlaybackLease() async throws {
        let tone = try await downloadCompleted("tone")
        let chime = try await downloadCompleted("chime")
        let model = DownloadListModel(controller: manager)
        guard case .available(let lease) = await model.beginPlayback(of: tone) else { return XCTFail("tone plays") }

        model.requestRemoval(of: [chime], title: nil)
        await model.confirmRemoval()
        XCTAssertEqual(model.playbackLease, lease, "another item's removal keeps playback")

        model.requestRemoval(of: [tone], title: nil)
        await model.confirmRemoval()
        XCTAssertNil(model.playbackLease)
        let manager = manager!
        let gone = await eventually { await manager.state(for: tone) == .notDownloaded }
        XCTAssertTrue(gone)
    }

    /// A removal sent to the manager directly shows up as `removing` in the observed list; the
    /// model then ends the playback lease that holds it.
    func testObservedRemovalOfThePlayingItemEndsItsPlaybackLease() async throws {
        let tone = try await downloadCompleted("tone")
        let model = DownloadListModel(controller: manager)
        let observation = Task { await model.observe() }
        guard case .available = await model.beginPlayback(of: tone) else { return XCTFail("tone plays") }

        try await manager.remove(tone)
        let manager = manager!
        let gone = await eventually { await manager.state(for: tone) == .notDownloaded }
        XCTAssertTrue(gone, "the observed removal released the playback lease")
        XCTAssertNil(model.playbackLease)
        XCTAssertTrue(model.openLeases.isEmpty)
        observation.cancel()
        await observation.value
    }

    // MARK: Manager-wide values

    func testExternalPolicyChangeReachesTheVisibleModel() async throws {
        let model = DownloadListModel(controller: manager)
        let observation = Task { await model.observe() }
        let loaded = await eventually { model.defaultPolicy == .default }
        XCTAssertTrue(loaded)

        // Set elsewhere in the app, with no item in the list.
        let deferred = NetworkPolicy(allowsCellular: true, allowsExpensive: true, allowsConstrained: true, scheduling: .deferred)
        try await manager.setDefaultPolicy(deferred)
        let updated = await eventually { model.defaultPolicy == deferred }
        XCTAssertTrue(updated, "the picker follows a policy set outside the model")

        // Choosing in the picker now keeps the current scheduling, not a stale one.
        await model.setDefaultPolicy(.unmeteredOnly)
        let stored = await manager.defaultPolicy()
        XCTAssertEqual(stored, NetworkPolicyChoice.unmeteredOnly.policy(scheduling: .deferred))
        observation.cancel()
        await observation.value
    }

    func testObservationStartedBeforeStartShowsThePersistedPolicy() async throws {
        // Persist a policy, then hand the root to a new manager that is observed before start.
        let persisted = NetworkPolicy(allowsCellular: true, allowsExpensive: false, allowsConstrained: false)
        try await manager.setDefaultPolicy(persisted)
        let configuration = manager.configuration
        await manager.detach()

        let successor = DownloadManager(configuration: configuration)
        manager = successor
        let model = DownloadListModel(controller: successor)
        let observation = Task { await model.observe() }
        let bootstrapped = await eventually { model.isObserving && model.defaultPolicy != nil }
        XCTAssertTrue(bootstrapped)
        XCTAssertEqual(model.defaultPolicy, .default, "before start only the configured policy is known")

        try await successor.start()
        let loaded = await eventually { model.defaultPolicy == persisted }
        XCTAssertTrue(loaded, "the persisted policy replaces the configured one once start loaded it")
        observation.cancel()
        await observation.value
    }
}
