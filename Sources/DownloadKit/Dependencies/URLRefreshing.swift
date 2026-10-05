//
//  URLRefreshing.swift
//  DownloadKit
//

import Foundation

/// Lets the host supply a fresh source URL when a user retries an item that failed with
/// ``DownloadFailure/Kind/unauthorized`` (for example an expired signed link).
///
/// The item's identity and revision do not change.
public protocol URLRefreshing: Sendable {
    func refreshedURL(for id: DownloadID, metadata: DownloadMetadata) async throws -> URL
}
