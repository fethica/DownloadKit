import Foundation
import XCTest
@testable import DownloadKit

/// Wires a manager to fakes. Each harness gets a unique namespace and session identifier
/// unless told otherwise, because the owner registry is process-wide.
struct Harness {
    let namespace: String
    let sessionIdentifier: String
    let fileSystem: FakeFileSystem
    let store: InMemoryIndexStore
    let session: FakeTransferSession
    let clock: ManualClock
    let log: CallLog
    let finalizer: FakeFinalizer
    let pathSource: FakePathSource?
    let configuration: DownloadConfiguration

    init(
        namespace: String = Harness.uniqueName("ns"),
        sessionIdentifier: String = Harness.uniqueName("session"),
        fileSystem: FakeFileSystem = FakeFileSystem(),
        store: InMemoryIndexStore? = nil,
        session: FakeTransferSession? = nil,
        clock: ManualClock = ManualClock(),
        log: CallLog = CallLog(),
        pathSource: FakePathSource? = nil,
        snapshotInterval: TimeInterval = 0,
        retryPolicy: RetryPolicy = .default,
        jitter: Double = 0.5,
        reconciliationTimeout: TimeInterval = 20,
        backgroundWakeBudget: TimeInterval = 20,
        finalizationBudget: TimeInterval = 15,
        failingTransport: Bool = false
    ) throws {
        let store = store ?? InMemoryIndexStore(log: log)
        let session = session ?? FakeTransferSession(identifier: sessionIdentifier, log: log)
        self.namespace = namespace
        self.sessionIdentifier = sessionIdentifier
        self.fileSystem = fileSystem
        self.store = store
        self.session = session
        self.clock = clock
        self.log = log
        self.finalizer = FakeFinalizer(fileSystem: fileSystem)
        self.pathSource = pathSource
        self.configuration = try DownloadConfiguration(
            storageScope: StorageScope(namespace: namespace),
            sessionIdentifier: sessionIdentifier,
            retryPolicy: retryPolicy,
            snapshotInterval: snapshotInterval,
            reconciliationTimeout: reconciliationTimeout,
            backgroundWakeBudget: backgroundWakeBudget,
            finalizationBudget: finalizationBudget,
            dependencies: DownloadDependencies(
                transport: FakeTransferSessionFactory(session: session, fails: failingTransport),
                makeIndexStore: { _ in store },
                fileSystem: fileSystem,
                clock: clock,
                jitter: FixedJitter(value: jitter),
                pathSource: pathSource
            )
        )
    }

    func makeManager(urlRefresher: (any URLRefreshing)? = nil, backgroundEvents: BackgroundTransferEvents? = nil) -> DownloadManager {
        DownloadManager(configuration: configuration, urlRefresher: urlRefresher, finalizer: finalizer, backgroundEvents: backgroundEvents)
    }

    var root: URL {
        fileSystem.applicationSupport.appendingPathComponent(namespace, isDirectory: true)
    }

    func url(_ relative: RelativePath) -> URL {
        root.appendingPathComponent(relative.rawValue)
    }

    static func uniqueName(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}

/// Polls `condition` with cooperative yields (never sleeps) and fails if it never holds.
func eventually(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition never held: \(message)", file: file, line: line)
}
