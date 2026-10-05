//
//  DownloadFileSystem.swift
//  DownloadKit
//

import Foundation

/// What an inspection found at a path.
///
/// Inspection distinguishes a verified absence from a failed inspection: an inspection that
/// cannot complete (permission, file protection while the device is locked, an I/O error)
/// throws instead of returning ``absent``. Callers treat a thrown inspection as unknown and
/// never as absence.
public enum FileStatus: Hashable, Sendable {
    /// A regular file of `size` bytes.
    case file(size: Int64)
    /// Nothing exists at the path. Only a verified absence may be reported this way.
    case absent
}

/// The file operations the manager and its finaliser perform.
///
/// Every operation works on URLs under the resolved storage root. The production adapter is
/// ``LocalFileSystem``: `FileManager` and POSIX calls, backup exclusion, explicit file protection
/// on created directories, and refusal of paths that escape the root.
///
/// Capturing a finished download's temporary file is not part of this port: it must happen
/// synchronously inside the system callback, so it belongs to the transfer session adapter.
public protocol DownloadFileSystem: Sendable {
    /// The user-domain Application Support directory.
    func applicationSupportDirectory() async throws -> URL
    /// Creates a directory and its parents; succeeds when it already exists.
    func createDirectory(at url: URL) async throws
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) async throws
    /// Inspects `url`. Returns ``FileStatus/absent`` only for a verified absence and throws
    /// when the inspection itself fails.
    func inspectItem(at url: URL) async throws -> FileStatus
    /// The names of the entries directly inside a directory, for inventories of `staging/`
    /// and `media/`. Throws when the directory cannot be read.
    func contentsOfDirectory(at url: URL) async throws -> [String]
    /// Reads at most `maximumLength` bytes starting at `offset`. Returns fewer bytes only at
    /// the end of the file. Used for bounded, chunked hashing; never reads a whole file.
    func readBytes(at url: URL, offset: Int64, maximumLength: Int) async throws -> Data
    /// Flushes a file's contents to stable storage before it is renamed into place.
    func synchronizeFile(at url: URL) async throws
    /// Removes a file; succeeds when nothing exists at `url`.
    func removeItem(at url: URL) async throws
    /// Atomically renames within one volume.
    func moveItem(at source: URL, to destination: URL) async throws
}
