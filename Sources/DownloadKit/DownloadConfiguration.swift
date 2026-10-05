//
//  DownloadConfiguration.swift
//  DownloadKit
//

import Foundation

/// Everything a ``DownloadManager`` needs, chosen explicitly by the host.
public struct DownloadConfiguration: Sendable {
    /// The longest accepted session identifier.
    public static let maximumSessionIdentifierLength = 200

    /// Where durable state lives. See ``StorageScope`` for the storage root rule.
    public let storageScope: StorageScope
    /// The stable background session identifier. Never change it once shipped: transfers in
    /// flight are bound to it.
    public let sessionIdentifier: String
    /// The default network policy, used until the host persists another with
    /// ``DownloadManager/setDefaultPolicy(_:)``. A persisted value always wins.
    public var defaultPolicy: NetworkPolicy
    public var retryPolicy: RetryPolicy
    /// The minimum interval between two snapshot deliveries. Zero delivers every change.
    public var snapshotInterval: TimeInterval
    /// How long start-up reconciliation waits for the session to report its backlog
    /// delivered. When it passes, nothing is concluded about attempts whose task could not be
    /// found: they keep their intent and bytes, and ``DownloadManager/reconciliationStatus()``
    /// reports them as ``ReconciliationStatus/unresolved(items:reason:)``.
    public var reconciliationTimeout: TimeInterval
    /// The longest a background-wake completion handler waits for the wake's events to be
    /// committed. When the index cannot be updated in time, the handler is called anyway and
    /// the uncommitted events stay unacknowledged with the session, which delivers them again.
    public var backgroundWakeBudget: TimeInterval
    /// The time a finaliser is given to validate and rename one file. A finaliser that cannot
    /// finish by then defers; the capture stays and is finalised again later.
    public var finalizationBudget: TimeInterval
    public var dependencies: DownloadDependencies

    public init(
        storageScope: StorageScope,
        sessionIdentifier: String,
        defaultPolicy: NetworkPolicy = .default,
        retryPolicy: RetryPolicy = .default,
        snapshotInterval: TimeInterval = 0.25,
        reconciliationTimeout: TimeInterval = 20,
        backgroundWakeBudget: TimeInterval = 20,
        finalizationBudget: TimeInterval = 15,
        dependencies: DownloadDependencies
    ) throws {
        guard !sessionIdentifier.isEmpty, sessionIdentifier.count <= Self.maximumSessionIdentifierLength else {
            throw DownloadError.invalidSessionIdentifier(sessionIdentifier)
        }
        self.storageScope = storageScope
        self.sessionIdentifier = sessionIdentifier
        self.defaultPolicy = defaultPolicy
        self.retryPolicy = retryPolicy
        self.snapshotInterval = max(0, snapshotInterval)
        self.reconciliationTimeout = max(0, reconciliationTimeout)
        self.backgroundWakeBudget = max(0, backgroundWakeBudget)
        self.finalizationBudget = max(0, finalizationBudget)
        self.dependencies = dependencies
    }
}

/// The injectable collaborators of a manager.
///
/// Each one is a narrow protocol so tests can drive the manager with controlled events.
/// Production adapters: ``URLSessionTransport`` (foreground only in this version),
/// ``SQLiteIndexStore/opener(progressWriteInterval:clock:)``, ``LocalFileSystem``, ``SystemClock``
/// and ``SystemJitter``. There is no production path source yet.
public struct DownloadDependencies: Sendable {
    public var transport: any TransferSessionFactory
    /// Opens the index for a resolved storage root.
    public var makeIndexStore: @Sendable (_ storageRoot: URL) async throws -> any DownloadIndexStore
    public var fileSystem: any DownloadFileSystem
    public var clock: any DownloadClock
    public var jitter: any RetryJitter
    /// Optional path observation. Without it, wait reasons come from the transfer session.
    public var pathSource: (any NetworkPathSource)?

    public init(
        transport: any TransferSessionFactory,
        makeIndexStore: @escaping @Sendable (_ storageRoot: URL) async throws -> any DownloadIndexStore,
        fileSystem: any DownloadFileSystem,
        clock: any DownloadClock = SystemClock(),
        jitter: any RetryJitter = SystemJitter(),
        pathSource: (any NetworkPathSource)? = nil
    ) {
        self.transport = transport
        self.makeIndexStore = makeIndexStore
        self.fileSystem = fileSystem
        self.clock = clock
        self.jitter = jitter
        self.pathSource = pathSource
    }
}
