//
//  IndexContents.swift
//  DownloadKit
//

import Foundation

/// Everything an index holds.
public struct IndexContents: Hashable, Sendable, Codable {
    /// The schema version the contents were written with. See ``IndexSchema``.
    public var schemaVersion: Int
    /// The next attempt generation to allocate. Never decreases.
    public var nextGeneration: UInt64
    /// The persisted default policy. `nil` until the host changes it, so the configured
    /// default applies; an explicit stored value always wins over the configured one.
    public var defaultPolicy: NetworkPolicy?
    public var records: [IndexRecord]

    public init(schemaVersion: Int = IndexSchema.currentVersion, nextGeneration: UInt64 = 1, defaultPolicy: NetworkPolicy? = nil, records: [IndexRecord] = []) {
        self.schemaVersion = schemaVersion
        self.nextGeneration = nextGeneration
        self.defaultPolicy = defaultPolicy
        self.records = records
    }
}

/// One atomic index write.
///
/// A store applies all of it or none of it, and stamps ``IndexSchema/currentVersion``.
public struct IndexChangeSet: Hashable, Sendable {
    public var upserts: [IndexRecord]
    public var deletions: [DownloadID]
    public var nextGeneration: UInt64
    /// A new default policy, or `nil` to leave it unchanged.
    public var defaultPolicy: NetworkPolicy?

    public init(upserts: [IndexRecord] = [], deletions: [DownloadID] = [], nextGeneration: UInt64, defaultPolicy: NetworkPolicy? = nil) {
        self.upserts = upserts
        self.deletions = deletions
        self.nextGeneration = nextGeneration
        self.defaultPolicy = defaultPolicy
    }

    /// Applies the change set to `contents` (or to an empty index).
    public func applied(to contents: IndexContents?) -> IndexContents {
        var result = contents ?? IndexContents()
        var byID: [DownloadID: IndexRecord] = [:]
        for record in result.records { byID[record.id] = record }
        for record in upserts { byID[record.id] = record }
        for id in deletions { byID[id] = nil }
        result.records = byID.values.sorted { $0.id < $1.id }
        result.nextGeneration = max(result.nextGeneration, nextGeneration)
        if let defaultPolicy { result.defaultPolicy = defaultPolicy }
        result.schemaVersion = IndexSchema.currentVersion
        return result
    }
}
