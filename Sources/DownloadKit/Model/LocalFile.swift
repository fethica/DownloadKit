//
//  LocalFile.swift
//  DownloadKit
//

import Foundation

/// A read lease on a validated completed file.
///
/// While a lease is held, removing the item marks it ``DownloadState/removing`` but keeps the
/// file on disk. The file is deleted when the last lease ends. End every lease with
/// ``DownloadManager/endAccess(_:)``, or use ``DownloadManager/withLocalFile(for:_:)``.
///
/// A lease keeps its manager's ownership of the storage root alive: after
/// ``DownloadManager/detach()``, or after the manager itself is released, no other manager can
/// claim the root until every lease has ended, so no other owner can delete a leased file.
/// ``DownloadManager/endAccess(_:)`` always ends the lease at the manager that issued it, so a
/// successor manager can end it. Copies of a lease are the same lease.
public struct LocalFileLease: Hashable, Sendable {
    public let id: DownloadID
    /// The absolute file URL, valid until the lease ends.
    public let url: URL
    let token: UUID
    /// The owner whose storage claim this lease protects. Retained on purpose.
    let owner: DownloadEngine

    init(id: DownloadID, url: URL, token: UUID, owner: DownloadEngine) {
        self.id = id
        self.url = url
        self.token = token
        self.owner = owner
    }

    public static func == (lhs: LocalFileLease, rhs: LocalFileLease) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.token == rhs.token
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
        hasher.combine(token)
    }
}

/// The result of ``DownloadManager/localFile(for:)``.
public enum LocalFileResult: Hashable, Sendable {
    /// A validated completed file and the lease protecting it.
    case available(LocalFileLease)
    case unavailable(LocalFileUnavailableReason)
}

/// Why no local file can be handed out.
public enum LocalFileUnavailableReason: Hashable, Sendable {
    /// No record exists.
    case notDownloaded
    /// The item is queued, active, paused or waiting.
    case inProgress
    /// The item failed.
    case failed(DownloadFailure)
    /// The record says completed but the file is gone.
    case missing
    /// The file exists but does not match the recorded size or integrity.
    case corrupt
    /// The item is being removed.
    case removing
}
