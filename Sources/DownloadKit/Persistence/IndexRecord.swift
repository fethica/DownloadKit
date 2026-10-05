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
/// - transfer binding: ``binding`` (session identifier, task identifier, generation) and
///   ``stoppingBinding`` (a task the manager asked to stop and has not seen acknowledged);
/// - bytes and validators: ``bytesWritten``, ``expectedBytes``, ``validators``,
///   ``resumeDataPath``;
/// - finalisation: ``journal``, ``stagingPath``, ``finalizationDestination``, ``finalPath``,
///   ``integrity``.
///
/// Generations are allocated from one counter per index and never reused, so an event that
/// carries an older generation can never match a removed, replaced or re-enqueued item.
///
/// Secrets: request headers are never stored, and source URLs carrying a user or password
/// are rejected. The source URL, including its query, is stored as given; see
/// ``URLRefreshing`` for keeping signed query credentials out of the index.
///
/// External stores rebuild records with ``init(id:request:metadata:policy:phase:generation:automaticRetryCount:retryAt:binding:stoppingBinding:bytesWritten:expectedBytes:validators:integrity:journal:stagingPath:finalizationDestination:finalPath:resumeDataPath:createdAt:updatedAt:)``
/// or store them as opaque `Codable` values.
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
    /// The task of an earlier attempt that pause, cancel or remove asked to stop. It is kept
    /// until the session accepted the cancellation or reconciliation found the task gone, so a
    /// stop interrupted by process exit is enforced again on the next start.
    public internal(set) var stoppingBinding: TaskBinding?
    public internal(set) var bytesWritten: Int64
    public internal(set) var expectedBytes: Int64?
    public internal(set) var validators: ResponseValidators?
    public internal(set) var integrity: IntegrityRecord?
    public internal(set) var journal: FinalizationJournal
    public internal(set) var stagingPath: RelativePath?
    /// Where the finaliser renames the captured file: `media/item-<generation>` of the
    /// capturing attempt. Written in the same commit as the capture, before any rename, and
    /// kept until the completion commits or the file is cleaned up, so a file the finaliser
    /// may create is always owned by this record, including while it is being removed.
    public internal(set) var finalizationDestination: RelativePath?
    public internal(set) var finalPath: RelativePath?
    /// Opaque, optional, version-sensitive resume data captured from a paused or cancelled
    /// transfer. Never the source of truth for the item.
    public internal(set) var resumeDataPath: RelativePath?
    public internal(set) var createdAt: Date
    public internal(set) var updatedAt: Date

    /// Rebuilds a record from stored fields, for index stores outside this module.
    ///
    /// Throws ``DownloadError/invalidStoredRecord(_:)`` when the fields contradict each
    /// other: a binding newer than the record's generation, a completed record without a final
    /// path, or a captured journal without a staging path.
    public init(
        id: DownloadID,
        request: RequestIdentity,
        metadata: DownloadMetadata,
        policy: NetworkPolicy?,
        phase: RecordPhase,
        generation: UInt64,
        automaticRetryCount: Int,
        retryAt: Date?,
        binding: TaskBinding?,
        stoppingBinding: TaskBinding?,
        bytesWritten: Int64,
        expectedBytes: Int64?,
        validators: ResponseValidators?,
        integrity: IntegrityRecord?,
        journal: FinalizationJournal,
        stagingPath: RelativePath?,
        finalizationDestination: RelativePath? = nil,
        finalPath: RelativePath?,
        resumeDataPath: RelativePath?,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        if let binding, binding.generation > generation { throw DownloadError.invalidStoredRecord(id) }
        if case .completed = phase, finalPath == nil { throw DownloadError.invalidStoredRecord(id) }
        if journal == .captured, stagingPath == nil { throw DownloadError.invalidStoredRecord(id) }
        self.init(
            unchecked: id, request: request, metadata: metadata, policy: policy, phase: phase,
            generation: generation, automaticRetryCount: max(0, automaticRetryCount), retryAt: retryAt,
            binding: binding, stoppingBinding: stoppingBinding, bytesWritten: max(0, bytesWritten),
            expectedBytes: expectedBytes, validators: validators, integrity: integrity, journal: journal,
            stagingPath: stagingPath, finalizationDestination: finalizationDestination, finalPath: finalPath,
            resumeDataPath: resumeDataPath, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    init(
        unchecked id: DownloadID,
        request: RequestIdentity,
        metadata: DownloadMetadata,
        policy: NetworkPolicy?,
        phase: RecordPhase,
        generation: UInt64,
        automaticRetryCount: Int,
        retryAt: Date?,
        binding: TaskBinding?,
        stoppingBinding: TaskBinding?,
        bytesWritten: Int64,
        expectedBytes: Int64?,
        validators: ResponseValidators?,
        integrity: IntegrityRecord?,
        journal: FinalizationJournal,
        stagingPath: RelativePath?,
        finalizationDestination: RelativePath? = nil,
        finalPath: RelativePath?,
        resumeDataPath: RelativePath?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.request = request
        self.metadata = metadata
        self.policy = policy
        self.phase = phase
        self.generation = generation
        self.automaticRetryCount = automaticRetryCount
        self.retryAt = retryAt
        self.binding = binding
        self.stoppingBinding = stoppingBinding
        self.bytesWritten = bytesWritten
        self.expectedBytes = expectedBytes
        self.validators = validators
        self.integrity = integrity
        self.journal = journal
        self.stagingPath = stagingPath
        self.finalizationDestination = finalizationDestination
        self.finalPath = finalPath
        self.resumeDataPath = resumeDataPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The content revision of the item.
    public var revision: ContentRevision { request.revision }

    /// Files under the root owned by this record.
    public var ownedPaths: [RelativePath] {
        var paths = [finalPath, stagingPath, resumeDataPath].compactMap { $0 }
        if let finalizationDestination, !paths.contains(finalizationDestination) { paths.append(finalizationDestination) }
        return paths
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

    /// Rebuilds a stored request identity, for index stores outside this module.
    public init(sourceURL: URL, revision: ContentRevision, expectedLength: Int64?, checksum: ContentChecksum?) {
        self.sourceURL = sourceURL
        self.revision = revision
        self.expectedLength = expectedLength
        self.checksum = checksum
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

    public init(sessionIdentifier: String, taskIdentifier: Int, generation: UInt64) {
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.generation = generation
    }
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
/// Finalisation order:
/// 1. ``captured``: the downloaded temporary file was moved into `staging/` before the system
///    callback returned, and the capture (path, byte count, validators, and the planned
///    ``IndexRecord/finalizationDestination``) is committed with the record. Until that
///    commit the transfer session keeps the unacknowledged event and delivers it again after
///    a relaunch, so the capture never loses its association.
/// 2. The finaliser validates length and checksum, flushes the file and renames it to the
///    deterministic destination ``RelativePath`` `media/item-<generation>`. These steps are
///    not journaled separately: they are idempotent, and a finaliser that finds the staging
///    file gone and a valid file at the destination reports it as finalised.
/// 3. ``committed``: the completed record was committed; only now is the item completed.
///    ``rejected``: validation failed; the capture of this attempt was consumed and its files
///    are queued for deletion.
///
/// One capture per attempt: once an attempt's capture was received (``captured``,
/// ``committed`` or ``rejected``), a replay of a completion for the same attempt never
/// captures again, whatever happened to the record since. Only a new attempt (a new
/// generation) resets the journal to ``notStarted``.
///
/// Start-up recovery rule: an active, paused or cancelled record whose journal is `captured`
/// keeps its bytes. Active ones are finalised again for the same generation once the session
/// delivered its backlog, which covers an interruption before validation, between rename and
/// commit, and a deferred finalisation. A committed record whose file is verifiably absent
/// becomes ``RecordPhase/missing``. A completed file that replaces an older one never
/// overwrites it, because each generation has its own destination; the older file is
/// deleted only after the newer record commits.
public enum FinalizationJournal: String, Hashable, Sendable, Codable {
    case notStarted
    case captured
    case committed
    case rejected
}
