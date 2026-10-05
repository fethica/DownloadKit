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
///
/// A version is raised whenever a field is added that an older build would silently drop when
/// it rewrites a record, so the older build refuses the index instead of losing that state.
/// Versions:
/// - 1: the first schema.
/// - 2: records gained ``IndexRecord/stoppedWhileUnconfirmed``, ``IndexRecord/restartDeferred``
///   and ``IndexRecord/policyChangeDeferred``. Version 1 data is read as is (those fields read
///   as false, which is what a version 1 build knew) and stamped version 2 on its next write.
public enum IndexSchema {
    /// The schema version this build reads and writes.
    public static let currentVersion = 2
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
///   ``integrity``;
/// - unresolved attempt (schema 2): ``stoppedWhileUnconfirmed``, ``restartDeferred``,
///   ``policyChangeDeferred``.
///
/// Generations are allocated from one counter per index and never reused, so an event that
/// carries an older generation can never match a removed, replaced or re-enqueued item.
///
/// Secrets: request headers are never stored, and source URLs carrying a user or password
/// are rejected. The source URL, including its query, is stored as given; see
/// ``URLRefreshing`` for keeping signed query credentials out of the index.
///
/// External stores rebuild records with ``init(id:request:metadata:policy:phase:generation:automaticRetryCount:retryAt:binding:stoppingBinding:bytesWritten:expectedBytes:validators:integrity:journal:stagingPath:finalizationDestination:finalPath:resumeDataPath:stoppedWhileUnconfirmed:restartDeferred:policyChangeDeferred:createdAt:updatedAt:)``
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
    /// Where the finaliser renames the captured file: `media/item-<generation>[.ext]` of the
    /// capturing attempt. Written in the same commit as the capture, before any rename, and
    /// kept until the completion commits or the file is cleaned up, so a file the finaliser
    /// may create is always owned by this record, including while it is being removed.
    public internal(set) var finalizationDestination: RelativePath?
    public internal(set) var finalPath: RelativePath?
    /// Opaque, optional, version-sensitive resume data captured from a paused or cancelled
    /// transfer. Never the source of truth for the item.
    public internal(set) var resumeDataPath: RelativePath?
    /// The current attempt was paused or cancelled before any binding confirmed its task: the
    /// task may still run and its completion may still arrive. Kept until the attempt's
    /// disposition is proven (its task found, its completion or failure received, or its end
    /// proven by the session's backlog), so a restart cannot replace it, before or after a
    /// relaunch.
    public internal(set) var stoppedWhileUnconfirmed: Bool
    /// A resume or retry was asked for while ``stoppedWhileUnconfirmed`` held. It is carried
    /// out once the attempt's disposition is known.
    public internal(set) var restartDeferred: Bool
    /// A policy change arrived while the attempt was unconfirmed. It is enforced when the
    /// attempt's task is found (the task is cancelled and the attempt restarted under the
    /// current policy) or dropped when the attempt provably ended.
    public internal(set) var policyChangeDeferred: Bool
    public internal(set) var createdAt: Date
    public internal(set) var updatedAt: Date

    /// Rebuilds a record from stored fields, for index stores outside this module.
    ///
    /// Throws ``DownloadError/invalidStoredRecord(_:)`` when the fields contradict each
    /// other: a binding newer than the record's generation, a completed record without a final
    /// path, a captured journal without a staging path, or a deferred restart without an
    /// unconfirmed stop.
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
        stoppedWhileUnconfirmed: Bool = false,
        restartDeferred: Bool = false,
        policyChangeDeferred: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        if let binding, binding.generation > generation { throw DownloadError.invalidStoredRecord(id) }
        if case .completed = phase, finalPath == nil { throw DownloadError.invalidStoredRecord(id) }
        if journal == .captured, stagingPath == nil { throw DownloadError.invalidStoredRecord(id) }
        if restartDeferred, !stoppedWhileUnconfirmed { throw DownloadError.invalidStoredRecord(id) }
        self.init(
            unchecked: id, request: request, metadata: metadata, policy: policy, phase: phase,
            generation: generation, automaticRetryCount: max(0, automaticRetryCount), retryAt: retryAt,
            binding: binding, stoppingBinding: stoppingBinding, bytesWritten: max(0, bytesWritten),
            expectedBytes: expectedBytes, validators: validators, integrity: integrity, journal: journal,
            stagingPath: stagingPath, finalizationDestination: finalizationDestination, finalPath: finalPath,
            resumeDataPath: resumeDataPath, stoppedWhileUnconfirmed: stoppedWhileUnconfirmed,
            restartDeferred: restartDeferred, policyChangeDeferred: policyChangeDeferred,
            createdAt: createdAt, updatedAt: updatedAt
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
        stoppedWhileUnconfirmed: Bool = false,
        restartDeferred: Bool = false,
        policyChangeDeferred: Bool = false,
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
        self.stoppedWhileUnconfirmed = stoppedWhileUnconfirmed
        self.restartDeferred = restartDeferred
        self.policyChangeDeferred = policyChangeDeferred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, request, metadata, policy, phase, generation, automaticRetryCount, retryAt, binding
        case stoppingBinding, bytesWritten, expectedBytes, validators, integrity, journal, stagingPath
        case finalizationDestination, finalPath, resumeDataPath, stoppedWhileUnconfirmed, restartDeferred
        case policyChangeDeferred, createdAt, updatedAt
    }

    /// Decodes a record of any supported schema version; fields added in version 2 read as
    /// false when absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DownloadID.self, forKey: .id)
        request = try container.decode(RequestIdentity.self, forKey: .request)
        metadata = try container.decode(DownloadMetadata.self, forKey: .metadata)
        policy = try container.decodeIfPresent(NetworkPolicy.self, forKey: .policy)
        phase = try container.decode(RecordPhase.self, forKey: .phase)
        generation = try container.decode(UInt64.self, forKey: .generation)
        automaticRetryCount = try container.decode(Int.self, forKey: .automaticRetryCount)
        retryAt = try container.decodeIfPresent(Date.self, forKey: .retryAt)
        binding = try container.decodeIfPresent(TaskBinding.self, forKey: .binding)
        stoppingBinding = try container.decodeIfPresent(TaskBinding.self, forKey: .stoppingBinding)
        bytesWritten = try container.decode(Int64.self, forKey: .bytesWritten)
        expectedBytes = try container.decodeIfPresent(Int64.self, forKey: .expectedBytes)
        validators = try container.decodeIfPresent(ResponseValidators.self, forKey: .validators)
        integrity = try container.decodeIfPresent(IntegrityRecord.self, forKey: .integrity)
        journal = try container.decode(FinalizationJournal.self, forKey: .journal)
        stagingPath = try container.decodeIfPresent(RelativePath.self, forKey: .stagingPath)
        finalizationDestination = try container.decodeIfPresent(RelativePath.self, forKey: .finalizationDestination)
        finalPath = try container.decodeIfPresent(RelativePath.self, forKey: .finalPath)
        resumeDataPath = try container.decodeIfPresent(RelativePath.self, forKey: .resumeDataPath)
        stoppedWhileUnconfirmed = try container.decodeIfPresent(Bool.self, forKey: .stoppedWhileUnconfirmed) ?? false
        restartDeferred = try container.decodeIfPresent(Bool.self, forKey: .restartDeferred) ?? false
        policyChangeDeferred = try container.decodeIfPresent(Bool.self, forKey: .policyChangeDeferred) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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

/// Evidence from the response that produced the bytes: its HTTP validators, status and media
/// type. Kept with the capture so finalisation can check it again and a later attempt can
/// compare validators.
public struct ResponseValidators: Hashable, Sendable, Codable {
    public var entityTag: String?
    public var lastModified: String?
    /// The final HTTP status (200, or 206 for a completed range continuation).
    public var statusCode: Int?
    /// The declared media type, lowercased, without parameters.
    public var mediaType: String?

    public init(entityTag: String? = nil, lastModified: String? = nil, statusCode: Int? = nil, mediaType: String? = nil) {
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.statusCode = statusCode
        self.mediaType = mediaType
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
/// 2. The finaliser validates the response evidence, length, content and checksum, flushes the
///    file and renames it to the deterministic destination `media/item-<generation>`, with an
///    allowlisted extension when the response declared a known media type. These steps are
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
