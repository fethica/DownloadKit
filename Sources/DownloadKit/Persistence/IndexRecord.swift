//
//  IndexRecord.swift
//  DownloadKit
//

import Foundation

/// The persisted index schema.
///
/// Versioning rule: the index stores its schema version. A reader that finds a version newer
/// than ``currentVersion`` refuses to open it with ``DownloadError/unsupportedSchema(found:supported:)``
/// and leaves it untouched. An unreadable index fails with ``DownloadError/corruptIndex``
/// and is preserved. The package never resets, recreates or clears an index to recover from
/// a read error, and never deletes unrecognised files as start-up cleanup.
public enum IndexSchema {
    /// The schema version this build reads and writes.
    public static let currentVersion = 1
}

/// One persisted item in the index.
///
/// Field groups:
/// - identity: ``id``, ``request`` (source URL, revision, expected length, checksum);
/// - presentation: ``metadata`` and the optional per-item ``policy``;
/// - state: ``phase``, ``generation`` (attempt generation), ``automaticRetryCount`` and
///   ``retryAt`` (retry eligibility and time);
/// - transfer binding: ``binding`` (session identifier, task identifier, generation);
/// - bytes and validators: ``bytesWritten``, ``expectedBytes``, ``validators``,
///   ``resumeDataPath``;
/// - finalisation: ``journal``, ``stagingPath``, ``finalPath``, ``integrity``.
///
/// Generations are allocated from one counter per index and never reused, so an event that
/// carries an older generation can never match a removed, replaced or re-enqueued item.
///
/// Secrets: request headers and credentials are never stored. The source URL is stored as
/// given; hosts that use signed URLs should provide a ``URLRefreshing`` instead of long-lived
/// tokens.
public struct IndexRecord: Hashable, Sendable, Codable {
    public internal(set) var id: DownloadID
    public internal(set) var request: RequestIdentity
    public internal(set) var metadata: DownloadMetadata
    public internal(set) var policy: NetworkPolicy?
    public internal(set) var phase: RecordPhase
    public internal(set) var generation: UInt64
    public internal(set) var automaticRetryCount: Int
    public internal(set) var retryAt: Date?
    public internal(set) var binding: TaskBinding?
    public internal(set) var bytesWritten: Int64
    public internal(set) var expectedBytes: Int64?
    public internal(set) var validators: ResponseValidators?
    public internal(set) var integrity: IntegrityRecord?
    public internal(set) var journal: FinalizationJournal
    public internal(set) var stagingPath: RelativePath?
    public internal(set) var finalPath: RelativePath?
    /// Opaque, optional, version-sensitive resume data captured from a paused or cancelled
    /// transfer. Never the source of truth for the item.
    public internal(set) var resumeDataPath: RelativePath?
    public internal(set) var createdAt: Date
    public internal(set) var updatedAt: Date

    /// The content revision of the item.
    public var revision: ContentRevision { request.revision }

    /// Files under the root owned by this record.
    public var ownedPaths: [RelativePath] {
        [finalPath, stagingPath, resumeDataPath].compactMap { $0 }
    }
}

/// The persisted lifecycle phase of a record.
public enum RecordPhase: Hashable, Sendable, Codable {
    case queued
    case active
    case paused
    case waiting(WaitReason)
    case completed(at: Date)
    case failed(DownloadFailure)
    case removing
    case missing

    /// Queued, active or waiting for anything other than a scheduled retry: a transfer for the
    /// current generation is expected to exist or be submitted.
    var isAwaitingTransfer: Bool {
        switch self {
        case .queued, .active: return true
        case .waiting(let reason): return !reason.isRetrySchedule
        default: return false
        }
    }

    /// Queued, active or waiting for any reason.
    var isTransferring: Bool {
        switch self {
        case .queued, .active, .waiting: return true
        default: return false
        }
    }
}

/// The content identity of a record.
///
/// ``sourceURL`` may change without changing identity. ``revision``, ``expectedLength`` and
/// ``checksum`` define the content: a request that differs in any of them conflicts.
public struct RequestIdentity: Hashable, Sendable, Codable {
    public internal(set) var sourceURL: URL
    public let revision: ContentRevision
    public let expectedLength: Int64?
    public let checksum: ContentChecksum?

    init(_ request: DownloadRequest) {
        sourceURL = request.url
        revision = request.revision
        expectedLength = request.expectedLength
        checksum = request.checksum
    }

    func hasSameContent(as other: RequestIdentity) -> Bool {
        revision == other.revision && expectedLength == other.expectedLength && checksum == other.checksum
    }
}

/// Binds a record to one system transfer task.
///
/// Task identifiers are process-local and only meaningful together with the session
/// identifier and the attempt generation; they are never item identity.
public struct TaskBinding: Hashable, Sendable, Codable {
    public let sessionIdentifier: String
    public let taskIdentifier: Int
    public let generation: UInt64
}

/// HTTP validators of the response that produced the bytes.
public struct ResponseValidators: Hashable, Sendable, Codable {
    public var entityTag: String?
    public var lastModified: String?

    public init(entityTag: String? = nil, lastModified: String? = nil) {
        self.entityTag = entityTag
        self.lastModified = lastModified
    }
}

/// What was verified when a file completed.
public struct IntegrityRecord: Hashable, Sendable, Codable {
    /// The file length measured after finalisation.
    public var verifiedLength: Int64
    /// The checksum the bytes were verified against, when the host supplied one.
    public var checksum: ContentChecksum?

    public init(verifiedLength: Int64, checksum: ContentChecksum? = nil) {
        self.verifiedLength = verifiedLength
        self.checksum = checksum
    }
}

/// The finalisation journal of a record.
///
/// Finalisation order (each step is persisted before the next starts):
/// 1. ``captured``: the downloaded temporary file was moved into `staging/` before the system
///    callback returned.
/// 2. ``validated``: HTTP status, media type, length and checksum checks passed.
/// 3. ``renamed``: the captured file was flushed and atomically renamed into `media/`.
/// 4. ``committed``: the completed record was committed; only now is the item completed.
///
/// Start-up recovery rule: `captured` or `validated` are validated again; `renamed` checks the
/// final file and commits it; a committed record whose file is missing becomes
/// ``RecordPhase/missing``. A file rename and an index transaction are not one atomic
/// operation, so both interruption windows are recoverable from this journal.
public enum FinalizationJournal: String, Hashable, Sendable, Codable {
    case notStarted
    case captured
    case validated
    case renamed
    case committed
}
