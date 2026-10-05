//
//  LocalFileLeaseTests.swift
//  DownloadKitUITests
//
//  The model's lease handling against a real manager on the production adapters (foreground
//  URLSession with a URLProtocol fixture, SQLite index, local file system) in a temporary
//  directory. Leases cannot be made outside the core, so this is the only honest way to test
//  them from here.
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
}
