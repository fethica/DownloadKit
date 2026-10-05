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
    public var dependencies: DownloadDependencies

    public init(
        storageScope: StorageScope,
        sessionIdentifier: String,
        defaultPolicy: NetworkPolicy = .default,
        retryPolicy: RetryPolicy = .default,
        snapshotInterval: TimeInterval = 0.25,
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
        self.dependencies = dependencies
    }
}

/// The injectable collaborators of a manager.
///
/// Each one is a narrow protocol so tests can drive the manager with controlled events.
/// The production transfer session, index store, file system and path source adapters are
/// not implemented yet; ``SystemClock`` and ``SystemJitter`` are.
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
