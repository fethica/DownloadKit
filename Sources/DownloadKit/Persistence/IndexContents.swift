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
    /// Files the package decided to delete and has not yet verified deleted: discarded
    /// captures, replaced completed files, rejected captures. Kept apart from the files records
    /// own, and removed only after the deletion succeeded. Files that are neither owned nor
    /// listed here are unknown and never deleted automatically.
    public var cleanupPaths: [RelativePath]

    public init(schemaVersion: Int = IndexSchema.currentVersion, nextGeneration: UInt64 = 1, defaultPolicy: NetworkPolicy? = nil, records: [IndexRecord] = [], cleanupPaths: [RelativePath] = []) {
        self.schemaVersion = schemaVersion
        self.nextGeneration = nextGeneration
        self.defaultPolicy = defaultPolicy
        self.records = records
        self.cleanupPaths = cleanupPaths
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, nextGeneration, defaultPolicy, records, cleanupPaths
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        nextGeneration = try container.decode(UInt64.self, forKey: .nextGeneration)
        defaultPolicy = try container.decodeIfPresent(NetworkPolicy.self, forKey: .defaultPolicy)
        records = try container.decode([IndexRecord].self, forKey: .records)
        cleanupPaths = try container.decodeIfPresent([RelativePath].self, forKey: .cleanupPaths) ?? []
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
    /// Paths added to ``IndexContents/cleanupPaths``.
    public var cleanupQueued: [RelativePath]
    /// Paths removed from ``IndexContents/cleanupPaths`` after their deletion succeeded.
    public var cleanupCompleted: [RelativePath]

    public init(upserts: [IndexRecord] = [], deletions: [DownloadID] = [], nextGeneration: UInt64, defaultPolicy: NetworkPolicy? = nil, cleanupQueued: [RelativePath] = [], cleanupCompleted: [RelativePath] = []) {
        self.upserts = upserts
        self.deletions = deletions
        self.nextGeneration = nextGeneration
        self.defaultPolicy = defaultPolicy
        self.cleanupQueued = cleanupQueued
        self.cleanupCompleted = cleanupCompleted
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
        var cleanup = Set(result.cleanupPaths)
        cleanup.formUnion(cleanupQueued)
        cleanup.subtract(cleanupCompleted)
        result.cleanupPaths = cleanup.sorted { $0.rawValue < $1.rawValue }
        result.schemaVersion = IndexSchema.currentVersion
        return result
    }
}
