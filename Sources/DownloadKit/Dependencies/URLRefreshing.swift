//
//  URLRefreshing.swift
//  DownloadKit
//

import Foundation

/// Lets the host control the URL a transfer actually uses.
///
/// Persistence contract: the index stores the source URL given to
/// ``DownloadManager/enqueue(_:)`` (and any URL returned by ``refreshedURL(for:metadata:)``),
/// including its query. URLs with a user or password component are rejected with
/// ``DownloadError/credentialsInURL(_:)``. A host whose URLs carry signed query credentials
/// that must not be stored enqueues a credential-free source URL and returns the signed URL
/// from ``transferURL(for:sourceURL:metadata:)``, which is resolved before every submission and
/// never persisted by the package. The system transfer service may still keep the request of
/// a running task. The package never logs URLs.
///
/// The item's identity and revision never change through this protocol.
public protocol URLRefreshing: Sendable {
    /// A fresh source URL when a user retries an item that failed with
    /// ``DownloadFailure/Kind/unauthorized`` (for example an expired link). It is persisted.
    func refreshedURL(for id: DownloadID, metadata: DownloadMetadata) async throws -> URL

    /// The URL handed to the transfer session for one attempt. It is not persisted. Throwing
    /// fails the attempt as ``DownloadFailure/Kind/unauthorized``. The default returns
    /// `sourceURL`.
    func transferURL(for id: DownloadID, sourceURL: URL, metadata: DownloadMetadata) async throws -> URL
}

extension URLRefreshing {
    public func transferURL(for id: DownloadID, sourceURL: URL, metadata: DownloadMetadata) async throws -> URL {
        sourceURL
    }
}
