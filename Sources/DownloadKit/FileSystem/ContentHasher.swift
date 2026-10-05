//
//  ContentHasher.swift
//  DownloadKit
//
//  Bounded, chunked SHA-256 over a file read through the file system port. This file is the
//  only place in the package that imports CryptoKit.
//

import Foundation
import CryptoKit

enum ContentHasher {
    /// The largest read; a file is never loaded whole.
    static let chunkSize = 256 * 1024

    /// The lowercase hexadecimal SHA-256 of the file at `url`, or `nil` when `shouldContinue`
    /// returned false before a chunk (a deadline or a cancellation). A nonisolated async
    /// function: it runs off every actor, on the concurrent executor, so a caller on the
    /// main actor or on an engine is never blocked by the reads.
    static func sha256(
        of url: URL,
        fileSystem: any DownloadFileSystem,
        chunkSize: Int = ContentHasher.chunkSize,
        shouldContinue: @Sendable () async -> Bool
    ) async throws -> String? {
        var hasher = SHA256()
        var offset: Int64 = 0
        while true {
            guard await shouldContinue() else { return nil }
            let chunk = try await fileSystem.readBytes(at: url, offset: offset, maximumLength: chunkSize)
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
            if chunk.count < chunkSize { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
