//
//  TransferEvent.swift
//  DownloadKit
//

import Foundation

/// Identifies one system transfer task for one attempt of one item.
public struct TransferTaskReference: Hashable, Sendable {
    public let itemID: DownloadID
    public let generation: UInt64
    public let taskIdentifier: Int

    public init(itemID: DownloadID, generation: UInt64, taskIdentifier: Int) {
        self.itemID = itemID
        self.generation = generation
        self.taskIdentifier = taskIdentifier
    }

    /// Maps a task back to its item and attempt from the durable description written at
    /// submission (see ``TransferSubmission/taskDescription``). Returns `nil` for any
    /// description this package did not write.
    public init?(taskDescription: String?, taskIdentifier: Int) {
        guard let description = taskDescription, description.hasPrefix(Self.descriptionPrefix) else { return nil }
        let body = description.dropFirst(Self.descriptionPrefix.count)
        guard let separator = body.firstIndex(of: "/"),
              let generation = UInt64(body[body.startIndex..<separator]),
              let itemID = try? DownloadID(String(body[body.index(after: separator)...])) else { return nil }
        self.init(itemID: itemID, generation: generation, taskIdentifier: taskIdentifier)
    }

    static let descriptionPrefix = "downloadkit/1/"

    static func taskDescription(itemID: DownloadID, generation: UInt64) -> String {
        "\(descriptionPrefix)\(generation)/\(itemID.rawValue)"
    }
}

/// A task the system reports for a session, mapped or not.
public struct SystemTransferTask: Hashable, Sendable {
    public let taskIdentifier: Int
    /// The raw task description, exactly as the system returned it.
    public let taskDescription: String?

    public init(taskIdentifier: Int, taskDescription: String?) {
        self.taskIdentifier = taskIdentifier
        self.taskDescription = taskDescription
    }

    /// The item and attempt this task belongs to, or `nil` for a task the package did not
    /// create. Unmapped tasks are left alone, never adopted or cancelled.
    public var reference: TransferTaskReference? {
        TransferTaskReference(taskDescription: taskDescription, taskIdentifier: taskIdentifier)
    }
}

/// What the manager asks a ``TransferSession`` to start.
public struct TransferSubmission: Hashable, Sendable {
    public let itemID: DownloadID
    /// The attempt generation the session must echo in every event for this task.
    public let generation: UInt64
    /// The URL for this attempt. It may differ from the persisted source URL (see
    /// ``URLRefreshing/transferURL(for:sourceURL:metadata:)``).
    public let url: URL
    /// The effective policy, applied per request before the task is created.
    public let policy: NetworkPolicy
    /// Resume data captured from an earlier attempt. The session owns it from here on and may
    /// discard it when the server no longer accepts it (safe restart, never a blind append).
    public let resumeDataPath: RelativePath?
    public let expectedLength: Int64?

    public init(itemID: DownloadID, generation: UInt64, url: URL, policy: NetworkPolicy, resumeDataPath: RelativePath?, expectedLength: Int64?) {
        self.itemID = itemID
        self.generation = generation
        self.url = url
        self.policy = policy
        self.resumeDataPath = resumeDataPath
        self.expectedLength = expectedLength
    }

    /// The durable description the session sets on the task before resuming it, so the task
    /// can be mapped back to its item and generation after a relaunch even when the binding
    /// was never written. Parse it with ``TransferTaskReference/init(taskDescription:taskIdentifier:)``.
    public var taskDescription: String {
        TransferTaskReference.taskDescription(itemID: itemID, generation: generation)
    }

    func with(url: URL) -> TransferSubmission {
        TransferSubmission(itemID: itemID, generation: generation, url: url, policy: policy, resumeDataPath: resumeDataPath, expectedLength: expectedLength)
    }
}

/// A typed, immutable event from a transfer session.
///
/// Every event carries the attempt generation; events whose generation no longer matches the
/// record are ignored, and a file they reference is discarded only when no record owns it.
public enum TransferEvent: Hashable, Sendable {
    case progress(TransferTaskReference, bytesWritten: Int64, expectedBytes: Int64?)
    case waiting(TransferTaskReference, WaitReason)
    /// The downloaded file was already moved into package-owned staging before the system
    /// callback returned.
    ///
    /// Adapter prerequisite: the session sends `finished` only for a response it accepted as
    /// usable media: a 2xx status consistent with the request (a 206 only for a range it
    /// asked for, never a 200 appended to partial bytes) and not an error page. Anything else
    /// is reported as ``failed(_:_:)``. The validators recorded here are the evidence kept
    /// with the capture for finalisation and later resumption.
    case finished(TransferTaskReference, captured: RelativePath, bytes: Int64, validators: ResponseValidators?)
    case failed(TransferTaskReference, TransferFailure)
    case resumeDataCaptured(TransferTaskReference, RelativePath)

    /// Whether losing this event would lose state. Progress and waiting are advisory.
    var isTerminal: Bool {
        switch self {
        case .progress, .waiting: return false
        case .finished, .failed, .resumeDataCaptured: return true
        }
    }
}

/// One entry of a session's ordered event stream.
public struct TransferSessionEvent: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        /// A task event.
        case transfer(TransferEvent)
        /// Every event pending when the session was created or reconnected has been delivered.
        /// Only after this marker does the manager decide that an expected task is gone.
        case backlogDelivered
        /// The system finished delivering the events of a background wake. When the manager
        /// has applied everything before this marker, it calls the host's completion handler
        /// registered through ``DownloadManager/handleBackgroundEvents(forSession:completionHandler:)``.
        case backgroundEventsFinished
    }

    /// Strictly increasing per session; acknowledged with ``TransferSession/acknowledge(through:)``.
    public let sequence: UInt64
    public let payload: Payload

    public init(sequence: UInt64, payload: Payload) {
        self.sequence = sequence
        self.payload = payload
    }
}
