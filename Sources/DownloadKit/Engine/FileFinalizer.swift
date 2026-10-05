//
//  FileFinalizer.swift
//  DownloadKit
//

import Foundation

/// The production finaliser: validate, flush, rename, then let the manager commit.
///
/// Order, for one captured file:
/// 1. Evidence recorded with the capture: a status other than 200 or 206, or an HTML media
///    type, is an invalid response.
/// 2. The file: it must be non-empty, exactly as long as the capture recorded, as long as the
///    host's expected length when one was given, must not start like an HTML document, and must
///    match the host's checksum when one was given (SHA-256 in bounded chunks).
/// 3. Flush the captured file, then one atomic rename to the attempt's own destination
///    (`media/item-<generation>[.ext]`), which never holds another attempt's completed file: an
///    earlier valid file stays in place until the manager commits this one.
/// 4. Return ``FinalizationResult/finalized(finalPath:integrity:)``; the manager commits and
///    only then reports the item completed.
///
/// Repeatable: when the file in staging is gone and the destination holds a file, that file is
/// validated again and reported as finalised, which recovers an interruption between rename
/// and commit; its directories are flushed again first, so a rename whose directory flush failed
/// is reported only once it is durable (a failed flush defers). Before each step, and between hash chunks, it checks cancellation and the
/// request's deadline and returns ``FinalizationResult/deferred`` instead of running on; the
/// capture then stays for a later attempt. A file that is protected while the device is locked
/// also defers. Other storage errors fail with their reason.
struct FileFinalizer: DownloadFinalizing {
    let fileSystem: any DownloadFileSystem
    let clock: any DownloadClock
    var chunkSize = ContentHasher.chunkSize
    var rejectedMediaTypes: Set<String> = ResponseInspector().rejectedMediaTypes

    func finalize(_ request: FinalizationRequest) async -> FinalizationResult {
        let staging = request.storageRoot.appendingPathComponent(request.stagingPath.rawValue, isDirectory: false)
        let destination = request.storageRoot.appendingPathComponent(request.destination.rawValue, isDirectory: false)
        guard await canContinue(request) else { return .deferred }
        if let failure = evidenceFailure(request.validators) { return .failed(failure) }
        do {
            switch try await fileSystem.inspectItem(at: staging) {
            case .file(let size):
                if let outcome = try await validate(staging, size: size, request) { return outcome }
                try await fileSystem.synchronizeFile(at: staging)
                guard await canContinue(request) else { return .deferred }
                try await fileSystem.moveItem(at: staging, to: destination)
                return .finalized(finalPath: request.destination, integrity: IntegrityRecord(verifiedLength: size, checksum: request.checksum))
            case .absent:
                guard case .file(let size) = try await fileSystem.inspectItem(at: destination) else {
                    // Neither the captured file nor a renamed one exists: the bytes are gone.
                    return .failed(.storage(.other))
                }
                if let outcome = try await validate(destination, size: size, request) { return outcome }
                // The rename may have happened in an attempt whose directory flush failed (or
                // was interrupted): establish durability again before reporting success.
                try await fileSystem.synchronizeDirectory(at: destination.deletingLastPathComponent())
                try await fileSystem.synchronizeDirectory(at: staging.deletingLastPathComponent())
                guard await canContinue(request) else { return .deferred }
                return .finalized(finalPath: request.destination, integrity: IntegrityRecord(verifiedLength: size, checksum: request.checksum))
            }
        } catch {
            return Self.result(for: error)
        }
    }

    private func canContinue(_ request: FinalizationRequest) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await clock.now() < request.deadline
    }

    private func evidenceFailure(_ validators: ResponseValidators?) -> TransferFailure? {
        if let status = validators?.statusCode, status != 200, status != 206 { return .invalidResponse }
        if let mediaType = validators?.mediaType, rejectedMediaTypes.contains(mediaType) { return .invalidResponse }
        return nil
    }

    /// `nil` when the file is valid, otherwise the result to return.
    private func validate(_ url: URL, size: Int64, _ request: FinalizationRequest) async throws -> FinalizationResult? {
        guard size > 0 else { return .failed(.invalidResponse) }
        guard size == request.capturedBytes else { return .failed(.integrity) }
        if let expected = request.expectedLength, expected != size { return .failed(.integrity) }
        let head = try await fileSystem.readBytes(at: url, offset: 0, maximumLength: ResponseInspector.sniffLength)
        if ResponseInspector.looksLikeMarkup(head) { return .failed(.invalidResponse) }
        if let checksum = request.checksum {
            let finalizer = self
            guard let digest = try await ContentHasher.sha256(of: url, fileSystem: fileSystem, chunkSize: chunkSize, shouldContinue: { await finalizer.canContinue(request) }) else {
                return .deferred
            }
            guard digest == checksum.hexDigest else { return .failed(.integrity) }
        }
        return nil
    }

    private static func result(for error: any Error) -> FinalizationResult {
        guard let failure = error as? DownloadFileSystemError else { return .failed(.storage(.other)) }
        // A protected file, or a renamed file whose directory flush failed, keeps its capture
        // for a later attempt: neither is a reason to reject the bytes.
        if failure.kind == .fileProtection || failure.kind == .directoryFlushFailed { return .deferred }
        return .failed(.storage(failure.storageReason))
    }
}
