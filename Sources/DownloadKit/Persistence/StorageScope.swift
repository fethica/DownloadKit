//
//  StorageScope.swift
//  DownloadKit
//

import Foundation

/// Where a manager keeps its durable state.
///
/// Storage root rule:
/// - The root is `Application Support/<namespace>/`. There is no default namespace: the host
///   must choose one, so two features or two libraries never share a root by accident.
/// - There is no fallback to Caches or temporary storage. If the root cannot be created,
///   ``DownloadManager/start()`` throws ``DownloadError/storageUnavailable``.
/// - Inside the root the package owns the layout: the index, `staging/` for captured partial
///   or unvalidated files, and `media/` for completed files.
/// - `media/` and `staging/` are excluded from backup. The index is kept in backup, so a
///   restored device shows records whose files are gone; those are reported as
///   ``DownloadState/missing`` (downloadable again), never as completed.
/// - Every path stored in the index is relative to the root (see ``RelativePath``), because
///   the absolute sandbox path can change between installs and restores.
///
/// Namespace rules: 1 to 64 characters from `A-Z a-z 0-9 . _ -`, not starting with a dot.
public struct StorageScope: Hashable, Sendable {
    /// The maximum namespace length.
    public static let maximumNamespaceLength = 64

    /// The host-chosen directory name under Application Support.
    public let namespace: String

    public init(namespace: String) throws {
        guard Self.isValid(namespace) else { throw DownloadError.invalidNamespace(namespace) }
        self.namespace = namespace
    }

    private static func isValid(_ namespace: String) -> Bool {
        guard !namespace.isEmpty, namespace.count <= maximumNamespaceLength, !namespace.hasPrefix(".") else { return false }
        return namespace.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }
}

/// The resolved on-disk layout of a storage scope.
struct StorageLayout: Hashable, Sendable {
    static let mediaDirectory = "media"
    static let stagingDirectory = "staging"

    let root: URL

    init(applicationSupport: URL, scope: StorageScope) {
        root = applicationSupport.appendingPathComponent(scope.namespace, isDirectory: true)
    }

    var media: URL { root.appendingPathComponent(Self.mediaDirectory, isDirectory: true) }
    var staging: URL { root.appendingPathComponent(Self.stagingDirectory, isDirectory: true) }

    /// The owner-registry key for this root.
    var ownerKey: String { root.standardizedFileURL.path }

    func url(for path: RelativePath) -> URL {
        root.appendingPathComponent(path.rawValue, isDirectory: false)
    }
}
