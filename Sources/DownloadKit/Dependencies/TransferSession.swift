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
public protocol TransferSessionFactory: Sendable {
    /// Creates (or reconnects to) the session named `identifier`. `storageRoot` is the
    /// resolved root; finished files must be moved under its `staging/` directory before the
    /// system callback returns.
    func makeSession(identifier: String, storageRoot: URL) async throws -> any TransferSession
}

/// One transfer session: submits tasks, cancels them and reports ordered events.
public protocol TransferSession: Sendable {
    /// The session identifier.
    var identifier: String { get }
    /// Ordered events for every task of this session. A manager iterates it exactly once.
    var events: AsyncStream<TransferEvent> { get }
    /// Creates a task for `submission` and returns its task identifier. The policy is
    /// applied to the request before the task is created. Throw a ``TransferFailure`` to have
    /// the failure classified.
    func submit(_ submission: TransferSubmission) async throws -> Int
    /// Cancels a task, asking for resume data when `producingResumeData` is true. Resume data
    /// is delivered later as ``TransferEvent/resumeDataCaptured(_:_:)``.
    func cancel(taskIdentifier: Int, producingResumeData: Bool) async
    /// The tasks the system still knows about, used to reconcile the index on start.
    func activeTasks() async -> [TransferTaskReference]
}
