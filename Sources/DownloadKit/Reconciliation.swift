//
//  Reconciliation.swift
//  DownloadKit
//

import Foundation

/// Where start-up reconciliation stands.
///
/// At start the manager adopts every task the session still reports and applies every event
/// the session delivers before ``TransferSessionEvent/Payload/backlogDelivered`` (or a
/// background wake's ``TransferSessionEvent/Payload/backgroundEventsFinished``). Only then does
/// it decide that an expected task is gone and submit a replacement. Until that point a
/// missing task is not proof of anything.
public enum ReconciliationStatus: Hashable, Sendable {
    /// The manager has not started.
    case notStarted
    /// Waiting for the session to report its backlog delivered, until `deadline`.
    case awaitingBacklog(deadline: Date)
    /// Every restored attempt was adopted, completed or proven gone.
    case resolved
    /// Proof never came for these items. Nothing was concluded: they keep their intent, their
    /// captured bytes and their generation, and no replacement attempt was created. A later
    /// backlog or background-wake marker, a task found by ``DownloadManager/flushPendingWork()``
    /// or the next start resolves them.
    case unresolved(items: [DownloadID], reason: ReconciliationUnresolvedReason)
}

/// Why reconciliation is unresolved.
public enum ReconciliationUnresolvedReason: String, Hashable, Sendable {
    /// ``DownloadConfiguration/reconciliationTimeout`` passed without the backlog marker.
    case deadlineExceeded
    /// The session's event stream finished without the backlog marker.
    case sessionEnded
}
