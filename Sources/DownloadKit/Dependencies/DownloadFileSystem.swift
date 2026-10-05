//
//  DownloadFileSystem.swift
//  DownloadKit
//

import Foundation

/// The file operations the manager performs.
///
/// The production adapter will use `FileManager`, set `isExcludedFromBackup`, apply explicit
/// file protection and reject paths that escape the root. It is not implemented yet.
public protocol DownloadFileSystem: Sendable {
    /// The user-domain Application Support directory.
    func applicationSupportDirectory() async throws -> URL
    /// Creates a directory and its parents; succeeds when it already exists.
    func createDirectory(at url: URL) async throws
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) async throws
    /// The size of a regular file, or `nil` when nothing exists at `url`.
    func fileSize(at url: URL) async -> Int64?
    /// Removes a file; succeeds when nothing exists at `url`.
    func removeItem(at url: URL) async throws
    /// Atomically renames within one volume.
    func moveItem(at source: URL, to destination: URL) async throws
}
