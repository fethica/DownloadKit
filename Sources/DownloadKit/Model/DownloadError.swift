//
//  DownloadError.swift
//  DownloadKit
//

import Foundation

/// Errors thrown by ``DownloadManager`` and the value types it accepts.
public enum DownloadError: Error, Hashable, Sendable {
    /// The identifier breaks the ``DownloadID`` rules.
    case invalidIdentifier(String)
    /// The namespace breaks the ``StorageScope`` rules.
    case invalidNamespace(String)
    /// The background session identifier is empty or too long.
    case invalidSessionIdentifier(String)
    /// A stored path is absolute, escapes the storage root or is otherwise unsafe.
    case invalidRelativePath(String)
    /// The request URL is not `http` or `https`.
    case unsupportedURL(DownloadID)
    /// A command arrived before ``DownloadManager/start()`` finished, or after
    /// ``DownloadManager/detach()``.
    case notStarted
    /// ``DownloadManager/start()`` was called twice on the same manager.
    case alreadyStarted
    /// Another manager in this process already owns the storage root or session identifier.
    case ownerAlreadyActive
    /// The durable storage root could not be resolved or created. There is no fallback to
    /// Caches or temporary storage.
    case storageUnavailable
    /// The index was written by a newer schema. It is left untouched; nothing is reset.
    case unsupportedSchema(found: Int, supported: Int)
    /// The index cannot be read. It is left untouched; nothing is reset.
    case corruptIndex
    /// The index rejected a write. In-memory state was not changed.
    case persistenceFailed
    /// The transfer session could not be created.
    case transportUnavailable
    /// The item exists with a different content revision, expected length or checksum.
    case conflictingRequest(DownloadID)
    /// No record exists for the identifier.
    case unknownItem(DownloadID)
    /// The item is being removed; enqueue it again after removal finishes.
    case itemBeingRemoved(DownloadID)
    /// A scoped file access was requested for an item without a usable completed file.
    case fileUnavailable(LocalFileUnavailableReason)
}
