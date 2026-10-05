//
//  LocalFileSystem.swift
//  DownloadKit
//

import Foundation

/// The production file system: `FileManager` and POSIX calls, confined to one base directory.
///
/// - The base is the user-domain Application Support directory, or the directory given to
///   ``init(applicationSupportDirectory:fileProtection:)``. The manager builds its storage root as
///   `<base>/<namespace>/`; this adapter never chooses Caches or a temporary directory.
/// - Every path must lie inside the base after `.` and `..` are resolved, and no existing
///   component below the base may be a symbolic link. Anything else throws
///   ``DownloadFileSystemError/Kind/escapesRoot`` and touches nothing.
/// - ``inspectItem(at:)`` returns ``FileStatus/absent`` only when the file system reports that
///   nothing exists; a failed inspection throws.
/// - ``moveItem(at:to:)`` is one POSIX `rename`, atomic within a volume and replacing the
///   destination, followed by a flush of the destination and the source directory. A flush that
///   fails throws ``DownloadFileSystemError/Kind/directoryFlushFailed`` after the rename (the
///   file is in place, its durability is not established). Across volumes it throws
///   ``DownloadFileSystemError/Kind/crossVolume``.
/// - Directories the manager creates get the configured file protection on platforms that
///   support it. The default, complete until first user authentication, keeps files readable
///   while the device is locked after the first unlock, which background transfers need.
///   This is not yet verified on a device.
/// - Errors are classified into ``DownloadFileSystemError`` (disk full, permission denied, file
///   protection and others) so callers can report them without guessing.
public struct LocalFileSystem: DownloadFileSystem {
    private let baseOverride: URL?
    /// The raw value of the file protection applied to created directories.
    private let fileProtection: String?

    /// Uses Application Support.
    public init(fileProtection: FileProtectionType? = .completeUntilFirstUserAuthentication) {
        self.baseOverride = nil
        self.fileProtection = fileProtection?.rawValue
    }

    /// Uses `directory` in place of Application Support, for tools and tests.
    public init(applicationSupportDirectory directory: URL, fileProtection: FileProtectionType? = .completeUntilFirstUserAuthentication) {
        self.baseOverride = directory.standardizedFileURL
        self.fileProtection = fileProtection?.rawValue
    }

    public func applicationSupportDirectory() async throws -> URL {
        try base(creating: true)
    }

    public func createDirectory(at url: URL) async throws {
        let target = try confined(url)
        try classified {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if let fileProtection {
            try classified {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType(rawValue: fileProtection)], ofItemAtPath: target.path)
            }
        }
        #endif
    }

    public func setExcludedFromBackup(_ excluded: Bool, at url: URL) async throws {
        var target = try confined(url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try classified { try target.setResourceValues(values) }
    }

    public func inspectItem(at url: URL) async throws -> FileStatus {
        let target = try confined(url)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        } catch {
            let failure = DownloadFileSystemError(error)
            if failure.kind == .notFound { return .absent }
            throw failure
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DownloadFileSystemError(kind: .notARegularFile)
        }
        return .file(size: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    public func contentsOfDirectory(at url: URL) async throws -> [String] {
        let target = try confined(url)
        return try classified { try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() }
    }

    public func readBytes(at url: URL, offset: Int64, maximumLength: Int) async throws -> Data {
        let target = try confined(url)
        return try classified {
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: max(0, maximumLength)) ?? Data()
        }
    }

    public func synchronizeFile(at url: URL) async throws {
        let target = try confined(url)
        try classified {
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    public func removeItem(at url: URL) async throws {
        let target = try confined(url)
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            let failure = DownloadFileSystemError(error)
            if failure.kind == .notFound { return }
            throw failure
        }
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        let from = try confined(source)
        let to = try confined(destination)
        guard rename(from.path, to.path) == 0 else {
            throw DownloadFileSystemError(posixCode: errno)
        }
        // The rename is visible now; it is durable only once both directory entries are.
        let destinationDirectory = to.deletingLastPathComponent()
        let sourceDirectory = from.deletingLastPathComponent()
        try Self.synchronizeDirectory(destinationDirectory)
        if sourceDirectory.path != destinationDirectory.path {
            try Self.synchronizeDirectory(sourceDirectory)
        }
    }

    public func synchronizeDirectory(at url: URL) async throws {
        try Self.synchronizeDirectory(try confined(url))
    }

    // MARK: Confinement

    private func base(creating: Bool) throws -> URL {
        if let baseOverride {
            if creating {
                try classified { try FileManager.default.createDirectory(at: baseOverride, withIntermediateDirectories: true) }
            }
            return baseOverride
        }
        return try classified {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: creating)
        }.standardizedFileURL
    }

    /// `url` resolved against `.` and `..`, inside the base, with no symbolic link below it
    /// (the shared ``PathConfinement`` rule).
    func confined(_ url: URL) throws -> URL {
        try PathConfinement.confined(url, within: try base(creating: false))
    }

    private func classified<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DownloadFileSystemError {
            throw error
        } catch {
            throw DownloadFileSystemError(error)
        }
    }

    /// Flushes a directory entry change (a rename) to stable storage. A directory that cannot be
    /// opened or flushed throws ``DownloadFileSystemError/Kind/directoryFlushFailed``: the change
    /// is visible but its durability is not established.
    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw DownloadFileSystemError(kind: .directoryFlushFailed, code: Int(errno))
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DownloadFileSystemError(kind: .directoryFlushFailed, code: Int(errno))
        }
    }
}

/// A classified file system failure.
public struct DownloadFileSystemError: Error, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// No space left on the volume (or quota exceeded).
        case diskFull
        /// The process may not read or write the item.
        case permissionDenied
        /// The item is protected while the device is locked. Classified from `EPERM`; this
        /// heuristic is not yet verified on a device.
        case fileProtection
        /// The path leaves the storage base or goes through a symbolic link.
        case escapesRoot
        /// Something other than a regular file is at a file path.
        case notARegularFile
        /// A rename across volumes, which cannot be atomic.
        case crossVolume
        /// Nothing exists at the path.
        case notFound
        /// A directory entry change (a rename) happened but flushing the directory failed, so
        /// the change may not survive a power loss. The renamed file is in place.
        case directoryFlushFailed
        case other
    }

    public let kind: Kind
    /// The underlying POSIX or Cocoa error code, when there is one.
    public let code: Int?

    public init(kind: Kind, code: Int? = nil) {
        self.kind = kind
        self.code = code
    }

    /// Classifies a `FileManager`, `FileHandle` or POSIX error.
    public init(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            self.init(posixCode: Int32(nsError.code))
            return
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            let posix = DownloadFileSystemError(posixCode: Int32(underlying.code))
            if posix.kind != .other {
                self = posix
                return
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError: self.init(kind: .diskFull, code: nsError.code)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError: self.init(kind: .permissionDenied, code: nsError.code)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: self.init(kind: .notFound, code: nsError.code)
            default: self.init(kind: .other, code: nsError.code)
            }
            return
        }
        self.init(kind: .other, code: nsError.code)
    }

    init(posixCode: Int32) {
        let kind: Kind
        switch posixCode {
        case ENOSPC, EDQUOT: kind = .diskFull
        case EACCES, EROFS: kind = .permissionDenied
        case EPERM: kind = .fileProtection
        case ENOENT: kind = .notFound
        case EXDEV: kind = .crossVolume
        default: kind = .other
        }
        self.init(kind: kind, code: Int(posixCode))
    }

    /// The storage reason recorded when this failure ends an attempt.
    public var storageReason: StorageFailureReason {
        switch kind {
        case .diskFull: return .diskFull
        case .permissionDenied: return .permissionDenied
        case .fileProtection: return .fileProtection
        case .escapesRoot, .notARegularFile, .crossVolume, .notFound, .directoryFlushFailed, .other: return .other
        }
    }
}
