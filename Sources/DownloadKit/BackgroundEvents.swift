//
//  BackgroundEvents.swift
//  DownloadKit
//
//  Holds the host's background-wake completion handlers until the manager has applied every
//  session event of the wake.
//

import Foundation

/// Exactly-once holder for background-wake completion handlers.
///
/// Ordering assumption, as documented by the platform: the host forwards the wake (and its
/// handler) before the system finishes delivering the session's events. A handler registered
/// before ``DownloadManager/start()`` simply waits. Each registered handler is called once, on
/// the main actor, when the manager has applied everything up to the session's
/// ``TransferSessionEvent/Payload/backgroundEventsFinished`` marker. A marker with no waiting
/// handler calls nothing and is not remembered.
@MainActor
final class BackgroundEventsCoordinator {
    private var handlers: [() -> Void] = []

    nonisolated init() {}

    var pendingHandlerCount: Int { handlers.count }

    func register(_ handler: @escaping () -> Void) {
        handlers.append(handler)
    }

    func eventsApplied() {
        let pending = handlers
        handlers = []
        for handler in pending { handler() }
    }
}
