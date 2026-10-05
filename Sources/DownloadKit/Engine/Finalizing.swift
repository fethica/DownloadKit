//
//  Finalizing.swift
//  DownloadKit
//
//  The seam between a captured file and a committed completion: validation (status, media type,
//  length, checksum), flush, atomic rename into media/, then commit.
//

import Foundation

struct FinalizationRequest: Sendable, Equatable {
    let id: DownloadID
    let generation: UInt64
    let stagingPath: RelativePath
    let storageRoot: URL
    let expectedLength: Int64?
    let checksum: ContentChecksum?
}

enum FinalizationResult: Sendable, Equatable {
    /// Validated, renamed into place; the record may be committed as completed.
    case finalized(finalPath: RelativePath, integrity: IntegrityRecord)
    /// Validation or storage failed; the captured bytes are discarded.
    case failed(TransferFailure)
    /// Not finalised now; the record stays captured and is recovered on a later start.
    case deferred
}

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
