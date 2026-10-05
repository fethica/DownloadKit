//
//  PathConfinement.swift
//  DownloadKit
//

import Foundation

/// The one root-confinement rule every adapter applies before it opens, creates, renames or
/// deletes anything under the storage root: ``LocalFileSystem``, the transfer adapter's
/// synchronous capture and durable inbox, and the SQLite index.
///
/// A path is accepted only when, after `.` and `..` are resolved, it lies at or below `base`
/// and no existing component below `base` (the target included) is a symbolic link. A
/// component that does not exist ends the check: nothing below it can be a link yet. A failed
/// inspection of a component is not treated as absence; it throws.
///
/// The check runs immediately before each use. It cannot exclude a link created between the
/// check and the use by another process with write access to the root; within the package's
/// own root nothing creates links.
enum PathConfinement {
    static func confined(_ url: URL, within base: URL) throws -> URL {
        let target = url.standardizedFileURL
        let basePath = trimmed(base.standardizedFileURL.path)
        guard target.isFileURL, target.path == basePath || target.path.hasPrefix(basePath + "/") else {
            throw DownloadFileSystemError(kind: .escapesRoot)
        }
        var current = basePath
        for component in target.path.dropFirst(basePath.count).split(separator: "/") {
            current += "/" + component
            var status = stat()
            guard lstat(current, &status) == 0 else {
                let code = errno
                if code == ENOENT { break }
                throw DownloadFileSystemError(posixCode: code)
            }
            if status.st_mode & S_IFMT == S_IFLNK {
                throw DownloadFileSystemError(kind: .escapesRoot)
            }
        }
        return target
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
