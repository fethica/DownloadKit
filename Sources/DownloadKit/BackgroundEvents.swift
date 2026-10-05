//
//  BackgroundEvents.swift
//  DownloadKit
//
//  Holds the host's background-wake completion handlers until the manager has applied every
//  session event of the wake, or until the wake budget passed.
//

import Foundation

/// Receives the system's background-session relaunch for the host, from the first moment of
/// the process, before any ``DownloadManager`` exists.
///
/// When a background transfer finishes while the app is suspended or was terminated by the
/// system, the system relaunches the app in the background and calls
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. The app must call
/// that completion handler once the session's events were handled, and must not keep it
/// forever. Create one instance as a stored property of the app delegate (with SwiftUI, of the
/// `@UIApplicationDelegateAdaptor` delegate), forward the callback to
/// ``handleEvents(forSession:completionHandler:)``, and pass the instance to every
/// ``DownloadManager`` you create (``DownloadManager/init(configuration:urlRefresher:backgroundEvents:)``).
/// Create and start the manager for that identifier at launch: starting it recreates the
/// background session under the same identifier, which is what makes the system deliver the
/// pending events.
///
/// Contract:
/// - Only the identifiers given at creation are accepted; any other identifier returns `false`
///   and the handler is not kept (the host stays responsible for it).
/// - A handler may arrive before the manager exists, before it started, or after. It is kept
///   until the manager for its identifier has applied every event up to the session's
///   wake-drained marker (``TransferSessionEvent/Payload/backgroundEventsFinished``), then
///   called once, on the main actor. A second callback (a duplicate forward, or a later wake)
///   adds a second handler; each one is called exactly once.
/// - When the wake's events cannot be committed within
///   ``DownloadConfiguration/backgroundWakeBudget`` (counted from the first unanswered
///   handler or marker the running manager saw), the waiting handlers are called anyway and
///   the uncommitted events stay unacknowledged with the session, which delivers them again.
/// - Without a started manager for its identifier, a handler is never called. Starting the
///   manager at launch is the host's part of the contract.
@MainActor
public final class BackgroundTransferEvents {
    private let coordinators: [String: BackgroundEventsCoordinator]

    /// Accepts the wakes of `sessionIdentifiers`: the ``DownloadConfiguration/sessionIdentifier``
    /// of each manager the app runs.
    public nonisolated init(sessionIdentifiers: Set<String>) {
        var coordinators: [String: BackgroundEventsCoordinator] = [:]
        for identifier in sessionIdentifiers { coordinators[identifier] = BackgroundEventsCoordinator() }
        self.coordinators = coordinators
    }

    /// The identifiers this instance accepts.
    public nonisolated var sessionIdentifiers: Set<String> { Set(coordinators.keys) }

    /// Keeps `completionHandler` for the manager of `identifier`. Returns `false`, without
    /// keeping it, for an identifier this instance does not accept.
    @discardableResult
    public func handleEvents(forSession identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard let coordinator = coordinators[identifier] else { return false }
        coordinator.register(completionHandler)
        return true
    }

    /// Handlers of `identifier` not yet called.
    public func pendingHandlerCount(forSession identifier: String) -> Int {
        coordinators[identifier]?.pendingHandlerCount ?? 0
    }

    nonisolated func coordinator(for identifier: String) -> BackgroundEventsCoordinator? {
        coordinators[identifier]
    }
}

/// Exactly-once holder for the background-wake completion handlers of one session identifier.
///
/// Each registered handler is called once, on the main actor: when the manager has applied
/// everything up to the session's ``TransferSessionEvent/Payload/backgroundEventsFinished``
/// marker, or when the wake budget passed. A marker with no waiting handler calls nothing and
/// is not remembered; a handler registered after its wake's marker was applied is released by
/// the budget.
@MainActor
final class BackgroundEventsCoordinator {
    private var handlers: [() -> Void] = []
    /// The running manager's notification that a handler arrived.
    private var listener: (@Sendable () -> Void)?

    nonisolated init() {}

    var pendingHandlerCount: Int { handlers.count }

    func register(_ handler: @escaping () -> Void) {
        handlers.append(handler)
        listener?()
    }

    /// Connects the running manager; returns the number of handlers already waiting. A later
    /// manager replaces an earlier one.
    func attach(_ listener: @escaping @Sendable () -> Void) -> Int {
        self.listener = listener
        return handlers.count
    }

    /// Calls every waiting handler once.
    func eventsApplied() {
        let pending = handlers
        handlers = []
        for handler in pending { handler() }
    }
}
