//
//  TransferSession.swift
//  DownloadKit
//

import Foundation

/// Creates the transfer session a manager owns.
///
/// The production adapter will wrap one background `URLSession` per session identifier, its
/// delegate and the synchronous capture of finished files into `staging/`. That adapter is
/// not implemented yet; until it is, a host must supply its own factory.
///
/// Ownership across managers: the factory, not the manager, owns the system session, its
/// delegate and the inbox of events the delegate produced. A manager that detaches stops
/// reading events but does not end the session. When a later manager asks for the same
/// identifier, the factory returns a session whose ``TransferSession/events`` stream has not
/// been iterated and that carries every event not yet acknowledged, followed by
/// ``TransferSessionEvent/Payload/backlogDelivered``.
public protocol TransferSessionFactory: Sendable {
    /// Creates (or reconnects to) the session named `identifier`. `storageRoot` is the
    /// resolved root; finished files must be moved under its `staging/` directory before the
    /// system callback returns.
    func makeSession(identifier: String, storageRoot: URL) async throws -> any TransferSession
}

/// One transfer session: submits tasks, cancels them and reports ordered events.
///
/// Scheduling: a manager owns exactly one session identifier. A per-item
/// ``NetworkPolicy/scheduling`` is applied per request where the platform allows it and is
/// otherwise a hint; policy-specific sessions are not supported.
public protocol TransferSession: Sendable {
    /// The session identifier.
    var identifier: String { get }

    /// Ordered events for every task of this session. A manager iterates it exactly once.
    ///
    /// Delivery contract:
    /// - Sequence numbers strictly increase.
    /// - Terminal events (``TransferEvent/finished(_:captured:bytes:validators:)``,
    ///   ``TransferEvent/failed(_:_:)``, ``TransferEvent/resumeDataCaptured(_:_:)``) are
    ///   never dropped. An event that was not acknowledged with ``acknowledge(through:)``
    ///   before the process ended is delivered again after reconnection, so a captured file
    ///   never loses its association with its task.
    /// - Progress and waiting events are advisory: they may be coalesced or dropped.
    /// - ``TransferSessionEvent/Payload/backlogDelivered`` is sent once per session object,
    ///   after every event that was pending when the session was created or reconnected.
    /// - ``TransferSessionEvent/Payload/backgroundEventsFinished`` is sent after the system
    ///   reports that it delivered all events of a background wake.
    /// - The stream finishes only when the session is invalidated. The manager then stops
    ///   ingesting; unresolved reconciliation waits for the next start.
    var events: AsyncStream<TransferSessionEvent> { get }

    /// Creates a task for `submission` and returns its task identifier. The policy is
    /// applied to the request, and ``TransferSubmission/taskDescription`` is set on the task,
    /// before the task is resumed. Throw a ``TransferFailure`` to have the failure classified.
    func submit(_ submission: TransferSubmission) async throws -> Int

    /// Cancels a task, asking for resume data when `producingResumeData` is true. Returns once
    /// the system has accepted the cancellation; the manager treats that return as the
    /// acknowledgement that ends its pending stop. Resume data is delivered later as
    /// ``TransferEvent/resumeDataCaptured(_:_:)``. Cancelling an unknown task does nothing.
    func cancel(taskIdentifier: Int, producingResumeData: Bool) async

    /// Every task the system still knows about for this session, including tasks whose
    /// description the package cannot map. Used to reconcile the index on start.
    func systemTasks() async -> [SystemTransferTask]

    /// Every event up to and including `sequence` has been durably applied to the index. The
    /// session may release its copies of those events and of nothing later.
    func acknowledge(through sequence: UInt64) async
}
