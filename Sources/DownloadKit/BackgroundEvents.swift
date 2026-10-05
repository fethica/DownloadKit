//
//  BackgroundEvents.swift
//  DownloadKit
//
//  Holds the host's background-wake completion handlers until the manager has applied every
//  session event of the wake, or until the handler's own deadline passed.
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
/// - Every accepted handler gets its own deadline, ``wakeBudget`` after it was accepted. The
///   deadline runs in the receiver, not in a manager: it holds when no manager exists yet,
///   when ``DownloadManager/start()`` fails or never finishes, and after
///   ``DownloadManager/detach()``. At the deadline the handler is called, and events not yet
///   committed stay unacknowledged with the session, which delivers them again; no transfer
///   and no index record is changed.
/// - A handler is called earlier when the running manager has applied every event up to the
///   session's wake-drained marker (``TransferSessionEvent/Payload/backgroundEventsFinished``)
///   that the system reported after the handler was accepted. A marker never releases a
///   handler accepted after the marker was reported, so a late marker of an earlier wake cannot
///   answer a newer wake.
/// - Each handler is called exactly once, on the main actor. A second callback (a duplicate
///   forward, or a later wake) adds a second handler with its own deadline.
@MainActor
public final class BackgroundTransferEvents {
    /// The longest a handler waits after it was accepted.
    public nonisolated let wakeBudget: TimeInterval
    private let coordinators: [String: BackgroundEventsCoordinator]

    /// Accepts the wakes of `sessionIdentifiers`: the ``DownloadConfiguration/sessionIdentifier``
    /// of each manager the app runs. `wakeBudget` bounds how long each handler is kept; keep it
    /// well below the time the system gives a background wake.
    public nonisolated convenience init(sessionIdentifiers: Set<String>, wakeBudget: TimeInterval = 20) {
        self.init(sessionIdentifiers: sessionIdentifiers, wakeBudget: wakeBudget, clock: SystemClock())
    }

    nonisolated init(sessionIdentifiers: Set<String>, wakeBudget: TimeInterval, clock: any DownloadClock) {
        let budget = max(0, wakeBudget)
        self.wakeBudget = budget
        var coordinators: [String: BackgroundEventsCoordinator] = [:]
        for identifier in sessionIdentifiers { coordinators[identifier] = BackgroundEventsCoordinator(budget: budget, clock: clock) }
        self.coordinators = coordinators
    }

    /// The identifiers this instance accepts.
    public nonisolated var sessionIdentifiers: Set<String> { Set(coordinators.keys) }

    /// Keeps `completionHandler` for the manager of `identifier` and starts its deadline.
    /// Returns `false`, without keeping it, for an identifier this instance does not accept.
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

/// The process-wide order of accepted wake handlers and of the system's wake-drained
/// callbacks: the monotonic uptime clock, read where each one happens, before any storage or
/// manager delay. A marker releases only the handlers accepted strictly before it was reported;
/// two readings that tie leave the handler to its deadline, never release it early.
enum WakeOrder {
    static func next() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// Exactly-once holder for the background-wake completion handlers of one session identifier.
///
/// Each registered handler is called once, on the main actor: at its own deadline, or earlier
/// when the manager has applied a wake-drained marker reported after the handler was accepted.
/// Both paths remove the handler before calling it. A marker reported before a handler was
/// accepted (a late marker of an earlier wake, or a wake whose marker overtook its handler)
/// never releases it; its deadline does.
@MainActor
final class BackgroundEventsCoordinator {
    private struct Waiting {
        let order: UInt64
        let handler: () -> Void
        let deadline: Task<Void, Never>
    }

    private let budget: TimeInterval
    private let clock: any DownloadClock
    private var waiting: [Waiting] = []

    nonisolated init(budget: TimeInterval, clock: any DownloadClock) {
        self.budget = max(0, budget)
        self.clock = clock
    }

    var pendingHandlerCount: Int { waiting.count }

    func register(_ handler: @escaping () -> Void) {
        let order = WakeOrder.next()
        let clock = self.clock
        let budget = self.budget
        // Holds the coordinator until the deadline, so a handler is answered even when every
        // manager and receiver reference is gone.
        let deadline = Task { @MainActor [self] in
            let due = await clock.now().addingTimeInterval(budget)
            do {
                try await clock.sleep(until: due)
            } catch {
                return
            }
            self.release { $0.order == order }
        }
        waiting.append(Waiting(order: order, handler: handler, deadline: deadline))
    }

    /// The manager applied everything up to a wake-drained marker reported at `markerOrder`:
    /// the handlers accepted before it are answered.
    func eventsApplied(through markerOrder: UInt64) {
        release { $0.order < markerOrder }
    }

    private func release(where matches: (Waiting) -> Bool) {
        let due = waiting.filter(matches)
        guard !due.isEmpty else { return }
        waiting.removeAll(where: matches)
        for entry in due {
            entry.deadline.cancel()
            entry.handler()
        }
    }
}
