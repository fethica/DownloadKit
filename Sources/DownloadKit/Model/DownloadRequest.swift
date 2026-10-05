//
//  DownloadRequest.swift
//  DownloadKit
//

import Foundation

/// What the host asks the manager to download.
public struct DownloadRequest: Hashable, Sendable {
    /// Stable identity of the item.
    public var id: DownloadID
    /// Where the bytes come from. Only `http` and `https` are accepted. The URL may change
    /// between requests for the same item without changing its identity.
    public var url: URL
    /// The content revision; see ``ContentRevision``.
    public var revision: ContentRevision
    /// The expected length in bytes, when the host knows it.
    public var expectedLength: Int64?
    /// A trusted checksum the completed file must match, when the host has one.
    public var checksum: ContentChecksum?
    /// Opaque presentation metadata.
    public var metadata: DownloadMetadata
    /// A per-item network policy override. `nil` follows the manager's default policy.
    public var policy: NetworkPolicy?

    public init(
        id: DownloadID,
        url: URL,
        revision: ContentRevision = .unversioned,
        expectedLength: Int64? = nil,
        checksum: ContentChecksum? = nil,
        metadata: DownloadMetadata = DownloadMetadata(),
        policy: NetworkPolicy? = nil
    ) {
        self.id = id
        self.url = url
        self.revision = revision
        self.expectedLength = expectedLength
        self.checksum = checksum
        self.metadata = metadata
        self.policy = policy
    }
}

/// Opaque host metadata stored with an item and returned in snapshots.
///
/// The package never interprets or logs these values. Do not put credentials or tokens here:
/// metadata is persisted in the index.
public struct DownloadMetadata: Hashable, Sendable, Codable {
    public var title: String?
    public var subtitle: String?
    /// A host grouping key (for example a series). Removing a group is done by passing its
    /// member identifiers explicitly; the package never removes files by group.
    public var group: String?
    public var userInfo: [String: String]

    public init(title: String? = nil, subtitle: String? = nil, group: String? = nil, userInfo: [String: String] = [:]) {
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.userInfo = userInfo
    }
}
