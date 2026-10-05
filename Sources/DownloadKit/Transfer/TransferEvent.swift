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
}

/// What the manager asks a ``TransferSession`` to start.
public struct TransferSubmission: Hashable, Sendable {
    public let itemID: DownloadID
    /// The attempt generation the session must echo in every event for this task.
    public let generation: UInt64
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
}

/// A typed, immutable event from a transfer session.
///
/// Sessions deliver events in order through one stream. Every event carries the attempt
/// generation; events whose generation no longer matches the record are ignored, and any file
/// they reference is discarded.
public enum TransferEvent: Hashable, Sendable {
    case progress(TransferTaskReference, bytesWritten: Int64, expectedBytes: Int64?)
    case waiting(TransferTaskReference, WaitReason)
    /// The downloaded file was already moved into package-owned staging before the system
    /// callback returned.
    case finished(TransferTaskReference, captured: RelativePath, bytes: Int64, validators: ResponseValidators?)
    case failed(TransferTaskReference, TransferFailure)
    case resumeDataCaptured(TransferTaskReference, RelativePath)
}
