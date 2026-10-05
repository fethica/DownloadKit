//
//  DownloadSnapshot.swift
//  DownloadKit
//

import Foundation

/// An immutable view of one item, delivered by ``DownloadManager/snapshots()``.
public struct DownloadSnapshot: Hashable, Sendable, Identifiable {
    public let id: DownloadID
    public let revision: ContentRevision
    public let metadata: DownloadMetadata
    public let state: DownloadState
    /// Bytes received for the current or completed attempt.
    public let bytesWritten: Int64
    /// Total bytes, when known from the host or the server.
    public let expectedBytes: Int64?
    /// Automatic retries spent in the current user attempt.
    public let automaticRetryCount: Int
    /// When the next automatic retry is due, if one is scheduled.
    public let retryAt: Date?
    public let updatedAt: Date

    public init(
        id: DownloadID,
        revision: ContentRevision,
        metadata: DownloadMetadata,
        state: DownloadState,
        bytesWritten: Int64,
        expectedBytes: Int64?,
        automaticRetryCount: Int,
        retryAt: Date?,
        updatedAt: Date
    ) {
        self.id = id
        self.revision = revision
        self.metadata = metadata
        self.state = state
        self.bytesWritten = bytesWritten
        self.expectedBytes = expectedBytes
        self.automaticRetryCount = automaticRetryCount
        self.retryAt = retryAt
        self.updatedAt = updatedAt
    }

    /// Fraction complete in `0...1`, only when it means something: the total size is known
    /// and the item is in progress or complete. `nil` means indeterminate progress.
    public var progress: Double? {
        switch state {
        case .completed:
            return 1
        case .queued, .active, .paused, .waiting:
            guard let expectedBytes, expectedBytes > 0 else { return nil }
            return min(1, max(0, Double(bytesWritten) / Double(expectedBytes)))
        case .notDownloaded, .failed, .removing, .missing:
            return nil
        }
    }

    /// True when the item completed. ``DownloadManager/localFile(for:)`` still validates the
    /// file before handing it out.
    public var isAvailableOffline: Bool {
        if case .completed = state { return true }
        return false
    }
}
