//
//  Finalizing.swift
//  DownloadKit
//
//  The seam between a captured file and a committed completion: validation (length,
//  checksum), flush, atomic rename into media/, then commit.
//

import Foundation

struct FinalizationRequest: Sendable, Equatable {
    let id: DownloadID
    let generation: UInt64
    let stagingPath: RelativePath
    /// The deterministic destination for this generation. A finaliser renames to exactly
    /// this path, so an interrupted rename is recoverable.
    let destination: RelativePath
    let storageRoot: URL
    let capturedBytes: Int64
    /// Response evidence recorded with the capture (see ``TransferEvent/finished(_:captured:bytes:validators:)``).
    let validators: ResponseValidators?
    let expectedLength: Int64?
    let checksum: ContentChecksum?
}

enum FinalizationResult: Sendable, Equatable {
    /// Validated, renamed into place; the record may be committed as completed.
    case finalized(finalPath: RelativePath, integrity: IntegrityRecord)
    /// Validation or storage failed; the captured bytes are discarded.
    case failed(TransferFailure)
    /// Not finalised now; the record stays captured and is finalised again on a later start
    /// or when the user resumes or retries it.
    case deferred
}

/// Finalisation contract:
/// - runs outside the manager's command chain; its result is applied only if the record is
///   still at the same generation with the same capture;
/// - is idempotent: when the staging file is gone and ``FinalizationRequest/destination``
///   holds a file that validates, it reports ``FinalizationResult/finalized(finalPath:integrity:)``;
/// - reads files in bounded chunks through ``DownloadFileSystem/readBytes(at:offset:maximumLength:)``
///   and flushes with ``DownloadFileSystem/synchronizeFile(at:)`` before renaming;
/// - returns ``FinalizationResult/deferred`` instead of running past a wake budget.
protocol DownloadFinalizing: Sendable {
    func finalize(_ request: FinalizationRequest) async -> FinalizationResult
}

/// The finaliser used until validation and atomic rename are implemented.
///
/// It never marks bytes completed: every captured file stays captured (journal `captured`), so
/// nothing unvalidated becomes playable.
struct DeferredFinalizer: DownloadFinalizing {
    func finalize(_ request: FinalizationRequest) async -> FinalizationResult {
        .deferred
    }
}
