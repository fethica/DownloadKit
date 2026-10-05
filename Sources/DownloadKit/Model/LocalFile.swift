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
public struct LocalFileLease: Hashable, Sendable {
    public let id: DownloadID
    /// The absolute file URL, valid until the lease ends.
    public let url: URL
    let token: UUID

    init(id: DownloadID, url: URL, token: UUID) {
        self.id = id
        self.url = url
        self.token = token
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
