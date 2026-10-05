//
//  URLSessionTransport.swift
//  DownloadKit
//

import Foundation

/// The production transfer session factory: delegate-based URLSession download tasks.
///
/// This version runs a **foreground** session only. Transfers stop when the process ends; the
/// background configuration, the relaunch path and the host's background-wake forwarding are
/// not part of it yet. ``Mode`` exists so a background mode can be added as an option without
/// changing this type's shape.
///
/// What it guarantees:
/// - Each task carries the description from ``TransferSubmission/taskDescription`` (item and
///   attempt generation) before it is resumed, so it can be mapped back without a stored
///   binding. The session identity is the URLSession the task belongs to.
/// - A finished download is judged (status, range continuation, length, media type) and, when
///   usable, moved into `staging/` inside the delegate callback, before it returns, with a
///   durable receipt. Only then is anything delivered.
/// - Terminal events are written to a durable inbox under `<root>/transfer/` before they are
///   delivered, keep their sequence numbers when delivered again (to a later session object
///   or after a relaunch), and are deleted only when acknowledged. The backlog marker follows
///   the replay, the system task list and every callback queued before it.
/// - Resume data is opaque: it is used only when it is a property list and the session's
///   network flags are no more permissive than the item's policy; otherwise the attempt starts
///   from zero. A continuation the server refuses (416) or answers with another representation
///   is started again from zero, never appended.
/// - Tasks the package did not create are listed by ``TransferSession/systemTasks()`` and
///   never cancelled, captured or reported.
/// - No URL, header or credential is written by the adapter or logged; the transfer URL of
///   each attempt comes from ``URLRefreshing/transferURL(for:sourceURL:metadata:)`` and lives
///   only in the system's request. The foreground session is ephemeral (no persistent cookie,
///   cache or credential storage).
public struct URLSessionTransport: TransferSessionFactory {
    /// How the system session is configured.
    public struct Mode: Hashable, Sendable {
        let rawValue: String

        /// An ephemeral session in this process. Transfers end with the process.
        public static let foreground = Mode(rawValue: "foreground")
    }

    public struct Options: Sendable {
        public var mode: Mode
        /// The network flags of the session configuration. A request's own flags can only
        /// narrow them, and a task created from resume data inherits them, so resume data is
        /// used only for items whose policy allows at least these networks. Defaults to
        /// ``NetworkPolicy/default``; a host whose items may use cellular sets
        /// ``NetworkPolicy/anyNetwork``.
        public var sessionNetworkAccess: NetworkPolicy
        /// Media types never accepted as a download (an error page served with a success
        /// status). Lowercased `type/subtype`.
        public var rejectedMediaTypes: Set<String>
        /// The time used to read HTTP-date `Retry-After` values.
        public var now: @Sendable () -> Date
        /// Adjusts the configuration before the session is created (timeouts, protocol classes in
        /// tests). The network flags set from ``sessionNetworkAccess`` should not be widened here.
        public var configure: (@Sendable (URLSessionConfiguration) -> Void)?

        public init(
            mode: Mode = .foreground,
            sessionNetworkAccess: NetworkPolicy = .default,
            rejectedMediaTypes: Set<String> = ["text/html", "application/xhtml+xml"],
            now: @escaping @Sendable () -> Date = { Date() },
            configure: (@Sendable (URLSessionConfiguration) -> Void)? = nil
        ) {
            self.mode = mode
            self.sessionNetworkAccess = sessionNetworkAccess
            self.rejectedMediaTypes = rejectedMediaTypes
            self.now = now
            self.configure = configure
        }

        func makeConfiguration(identifier: String) -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.allowsCellularAccess = sessionNetworkAccess.allowsCellular
            configuration.allowsExpensiveNetworkAccess = sessionNetworkAccess.allowsExpensive
            configuration.allowsConstrainedNetworkAccess = sessionNetworkAccess.allowsConstrained
            configure?(configuration)
            return configuration
        }
    }

    public let options: Options
    private let registry = TransferHostRegistry()

    public init(options: Options = Options()) {
        self.options = options
    }

    public func makeSession(identifier: String, storageRoot: URL) async throws -> any TransferSession {
        let host = try await registry.host(for: identifier, storageRoot: storageRoot, options: options)
        let events = await host.subscribe()
        return URLSessionTransferSession(identifier: identifier, events: events, host: host)
    }

    /// Ends every system session this transport created. Their event streams finish; a later
    /// ``makeSession(identifier:storageRoot:)`` for the same identifier fails. With
    /// `cancellingTasks` false, running transfers finish first.
    public func invalidate(cancellingTasks: Bool = false) async {
        await registry.invalidateAll(cancellingTasks: cancellingTasks)
    }

    func host(for identifier: String) async -> TransferSessionHost? {
        await registry.existing(identifier)
    }
}

/// The hosts of one transport, one per session identifier.
actor TransferHostRegistry {
    private var hosts: [String: TransferSessionHost] = [:]
    private var invalidated: Set<String> = []

    func host(for identifier: String, storageRoot: URL, options: URLSessionTransport.Options) async throws -> TransferSessionHost {
        if let host = hosts[identifier] {
            guard host.storageRoot.standardizedFileURL == storageRoot.standardizedFileURL else { throw TransferFailure.unknown }
            return host
        }
        guard !invalidated.contains(identifier) else { throw TransferFailure.unknown }
        let host: TransferSessionHost
        do {
            host = try TransferSessionHost(identifier: identifier, storageRoot: storageRoot, options: options)
        } catch {
            throw TransferFailure.storage(DownloadFileSystemError(error).storageReason)
        }
        hosts[identifier] = host
        await host.start()
        return host
    }

    func existing(_ identifier: String) -> TransferSessionHost? {
        hosts[identifier]
    }

    func invalidateAll(cancellingTasks: Bool) async {
        for (identifier, host) in hosts {
            await host.invalidate(cancellingTasks: cancellingTasks)
            invalidated.insert(identifier)
        }
        hosts = [:]
    }
}

/// One manager's view of a host.
struct URLSessionTransferSession: TransferSession {
    let identifier: String
    let events: AsyncStream<TransferSessionEvent>
    let host: TransferSessionHost

    func submit(_ submission: TransferSubmission) async throws -> Int {
        try await host.submit(submission)
    }

    func cancel(taskIdentifier: Int, producingResumeData: Bool) async {
        await host.cancel(taskIdentifier: taskIdentifier, producingResumeData: producingResumeData)
    }

    func systemTasks() async -> [SystemTransferTask] {
        await host.systemTasks()
    }

    func acknowledge(through sequence: UInt64) async {
        await host.acknowledge(through: sequence)
    }
}
