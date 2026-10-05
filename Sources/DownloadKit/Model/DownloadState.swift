//
//  DownloadState.swift
//  DownloadKit
//

import Foundation

/// The externally visible state of one item.
///
/// State names describe what the package knows, not a promise about operating system
/// scheduling: `queued` means the transfer was handed to the system, which decides when it
/// runs.
public enum DownloadState: Hashable, Sendable {
    /// No record exists for the identifier.
    case notDownloaded
    /// Handed to the transfer system; no bytes observed yet for this attempt.
    case queued
    /// Bytes are being received.
    case active
    /// Paused by the host. `resumable` is true when partial data was retained.
    case paused(resumable: Bool)
    /// Not progressing, with the most precise reason known.
    case waiting(WaitReason)
    /// Validated and available offline.
    case completed(at: Date)
    /// Stopped with a typed failure. ``DownloadManager/retry(_:)`` starts a new attempt.
    case failed(DownloadFailure)
    /// Being removed; owned files are deleted once active readers release them.
    case removing
    /// The record exists but its completed file is gone (deleted externally or not restored
    /// from a backup). Enqueue or retry downloads it again.
    case missing
}

/// Why an item is not progressing.
///
/// There is deliberately no "Waiting for Wi-Fi": the package cannot prove a network is
/// Wi-Fi, only that it is not expensive, constrained or cellular.
public enum WaitReason: Hashable, Sendable, Codable {
    /// The current network path is not allowed by the item's ``NetworkPolicy``.
    case networkPolicy
    /// No usable network path.
    case connectivity
    /// An automatic retry is scheduled. Timers only run while the process runs; after a
    /// relaunch the retry is re-evaluated against this date.
    case retryScheduled(at: Date)
    /// The system is holding the transfer for its own reasons.
    case system
    /// The package does not know a more precise reason.
    case unknown

    var isRetrySchedule: Bool {
        if case .retryScheduled = self { return true }
        return false
    }
}
