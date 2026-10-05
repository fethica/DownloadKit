//
//  URLSessionTransport.swift
//  DownloadKit
//

import Foundation

/// The production transfer session factory: delegate-based URLSession download tasks.
///
/// Two modes:
/// - ``Mode/foreground``: an ephemeral session in this process. Transfers end with the process.
/// - ``Mode/background``: a background session under the manager's stable session identifier.
///   The system runs its transfers out of process and keeps them while the app is suspended or
///   was terminated by the system, and relaunches the app in the background to deliver their
///   events (`sessionSendsLaunchEvents`). The host forwards that relaunch to
///   ``BackgroundTransferEvents`` (or ``DownloadManager/handleBackgroundEvents(forSession:completionHandler:)``);
///   see the README for the integration and the platform limits. Background sessions are
///   process-wide: every background transport in a process shares one session (and one
///   delegate, retained for the life of the process) per identifier, because the system allows
///   only one session object per background identifier.
///
/// Redirects: a foreground session asks its delegate, which refuses a redirect from HTTPS to
/// anything else. A background session follows redirects automatically without asking; there
/// the host's App Transport Security settings decide which destinations are reachable. In both
/// modes a finished body whose final URL left HTTPS is refused as an invalid response, never
/// captured; a task created from resume data may not expose its original request, and then
/// this check has nothing to compare.
///
/// What it guarantees, in both modes:
/// - Each task carries the description from ``TransferSubmission/taskDescription(sessionIdentifier:)``
///   (item, attempt generation and session identity) before it is resumed, so it can be mapped
///   back without a stored binding. A task whose description names another session is foreign.
/// - A finished download is judged (status, range continuation, length, media type) and, when
///   usable, moved into `staging/` inside the delegate callback, before it returns, with a
///   durable receipt. Only then is anything delivered.
/// - Terminal events are written to a durable inbox under `<root>/transfer/` before they are
///   delivered, keep their sequence numbers when delivered again (to a later session object
///   or after a relaunch), and are deleted only when acknowledged. The backlog marker follows
///   the replay, the system task list and every callback queued before it. The system's
///   wake-drained callback (`urlSessionDidFinishEvents(forBackgroundURLSession:)`) becomes
///   ``TransferSessionEvent/Payload/backgroundEventsFinished``, in order behind every event
///   before it and never ahead of one still waiting to be stored.
/// - Resume data is opaque: it is used only when it is a property list and the session's
///   network flags are no more permissive than the item's policy; otherwise the attempt starts
///   from zero. A continuation the server refuses (416) or answers with another representation
///   is started again from zero, never appended. That restart is recorded in the inbox inside
///   the callback, so a relaunch does not turn it into a failure, and the replacement is
///   submitted by the running manager with a transfer URL resolved for it, exactly like any
///   other attempt; the refused task's request is never reused.
/// - Tasks the package did not create are listed by ``TransferSession/systemTasks()`` and
///   never cancelled, captured or reported.
/// - No URL, header or credential is written by the adapter or logged; the transfer URL of
///   each attempt comes from ``URLRefreshing/transferURL(for:sourceURL:metadata:)`` and lives
///   only in the system's request. Neither mode keeps a URL cache, cookie store or credential
///   store.
///
/// What macOS tests cannot show: a background session's transfers run in a system process
/// that URLProtocol stubs cannot reach, so the background mode is covered by its configuration
/// and by the shared delegate and inbox code, not by an end-to-end transfer.
public struct URLSessionTransport: TransferSessionFactory {
    /// How the system session is configured.
    public struct Mode: Hashable, Sendable {
        let rawValue: String

        /// An ephemeral session in this process. Transfers end with the process.
        public static let foreground = Mode(rawValue: "foreground")
        /// A background session under the manager's session identifier: transfers continue
        /// while the app is suspended or after the system terminated it, and the system
        /// relaunches the app to deliver their events. Not after the user force-quits the app.
        public static let background = Mode(rawValue: "background")
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
        /// The longest one task may take, waiting included, before the system gives up on it
        /// (`timeoutIntervalForResource`). Defaults to seven days, the system's own default.
        public var resourceTimeout: TimeInterval
        /// Adjusts the configuration before the session is created (timeouts, protocol classes in
        /// tests). The network flags set from ``sessionNetworkAccess`` should not be widened here.
        public var configure: (@Sendable (URLSessionConfiguration) -> Void)?

        public init(
            mode: Mode = .foreground,
            sessionNetworkAccess: NetworkPolicy = .default,
            rejectedMediaTypes: Set<String> = ["text/html", "application/xhtml+xml"],
            resourceTimeout: TimeInterval = 7 * 24 * 60 * 60,
            now: @escaping @Sendable () -> Date = { Date() },
            configure: (@Sendable (URLSessionConfiguration) -> Void)? = nil
        ) {
            self.mode = mode
            self.sessionNetworkAccess = sessionNetworkAccess
            self.rejectedMediaTypes = rejectedMediaTypes
            self.resourceTimeout = max(1, resourceTimeout)
            self.now = now
            self.configure = configure
        }

        /// The session configuration for `identifier`.
        ///
        /// Mapping, both modes: the network flags come from ``sessionNetworkAccess`` (each
        /// request narrows them further with its item's policy), `waitsForConnectivity` is on,
        /// there is no URL cache, cookie store or credential store, and
        /// `timeoutIntervalForResource` is ``resourceTimeout``.
        ///
        /// Background mode only: `URLSessionConfiguration.background(withIdentifier:)` with the
        /// stable identifier, `sessionSendsLaunchEvents` on, and `isDiscretionary` from
        /// ``sessionNetworkAccess``'s ``NetworkPolicy/scheduling``: ``NetworkPolicy/Scheduling/userInitiated``
        /// (the default, for downloads a person asked for) is non-discretionary,
        /// ``NetworkPolicy/Scheduling/deferred`` lets the system postpone every task of the
        /// session (for example until the device is charging on Wi-Fi). Discretion is a session
        /// setting: one session cannot mix both, so a deferred item in a non-discretionary
        /// session is only marked with the background network service type.
        func makeConfiguration(identifier: String) -> URLSessionConfiguration {
            let configuration: URLSessionConfiguration
            if mode == .background {
                configuration = URLSessionConfiguration.background(withIdentifier: identifier)
                configuration.sessionSendsLaunchEvents = true
                configuration.isDiscretionary = sessionNetworkAccess.scheduling == .deferred
            } else {
                configuration = URLSessionConfiguration.ephemeral
            }
            configuration.waitsForConnectivity = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.allowsCellularAccess = sessionNetworkAccess.allowsCellular
            configuration.allowsExpensiveNetworkAccess = sessionNetworkAccess.allowsExpensive
            configuration.allowsConstrainedNetworkAccess = sessionNetworkAccess.allowsConstrained
            configuration.timeoutIntervalForResource = resourceTimeout
            configure?(configuration)
            return configuration
        }
    }

    public let options: Options
    private let registry: TransferHostRegistry

    public init(options: Options = Options()) {
        self.options = options
        // Background sessions are process-wide; foreground sessions belong to this transport.
        self.registry = options.mode == .background ? TransferHostRegistry.background : TransferHostRegistry()
    }

    public func makeSession(identifier: String, storageRoot: URL) async throws -> any TransferSession {
        let host = try await registry.host(for: identifier, storageRoot: storageRoot, options: options)
        let events = await host.subscribe()
        return URLSessionTransferSession(identifier: identifier, events: events, host: host)
    }

    /// Ends every system session this transport created (in background mode: every background
    /// session of the package in this process). Their event streams finish; a later
    /// ``makeSession(identifier:storageRoot:)`` for the same identifier fails in this process.
    /// With `cancellingTasks` false, running transfers finish first.
    public func invalidate(cancellingTasks: Bool = false) async {
        await registry.invalidateAll(cancellingTasks: cancellingTasks)
    }

    func host(for identifier: String) async -> TransferSessionHost? {
        await registry.existing(identifier)
    }

    /// Whether this transport uses the process-wide registry of background sessions.
    var usesProcessWideSessions: Bool { registry === TransferHostRegistry.background }
}

/// The hosts of one transport, one per session identifier. Background hosts live in one
/// process-wide registry: the system allows a single session object per background identifier,
/// and a later manager (after a detach) must reconnect to the same session and delegate.
actor TransferHostRegistry {
    static let background = TransferHostRegistry()

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
        // Claim every host before the first suspension: the actor is reentrant, so a host
        // created for a new identifier while an older one is still being invalidated is not
        // part of this operation and must survive it, and a lookup of a claimed identifier
        // is refused from this point on rather than after its invalidation finishes.
        let claimed = hosts
        hosts = [:]
        invalidated.formUnion(claimed.keys)
        for host in claimed.values {
            await host.invalidate(cancellingTasks: cancellingTasks)
        }
    }
}

/// A session that starts a refused continuation again through the manager, so the replacement
/// gets a transfer URL resolved for it.
protocol RestartingTransferSession: TransferSession {
    /// `handler` submits the attempt of the refused task again from zero; it returns `false`
    /// when the manager is not running.
    func setRestartHandler(_ handler: @escaping @Sendable (TransferTaskReference) async -> Bool) async
}

/// One manager's view of a host.
struct URLSessionTransferSession: RestartingTransferSession {
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

    func setRestartHandler(_ handler: @escaping @Sendable (TransferTaskReference) async -> Bool) async {
        await host.setRestartHandler(handler)
    }
}
