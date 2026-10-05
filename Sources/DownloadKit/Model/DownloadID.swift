//
//  DownloadID.swift
//  DownloadKit
//

import Foundation

/// A stable, host-supplied identifier for one downloadable item.
///
/// The identifier is the item's identity for its whole life: the source URL may change
/// (for example a refreshed signed link) without changing the identifier. Identifiers are
/// never used as file names; files are named from internal generation counters.
///
/// Rules: non-empty, at most ``maximumLength`` UTF-8 bytes, no control characters.
public struct DownloadID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The maximum length of an identifier in UTF-8 bytes.
    public static let maximumLength = 256

    /// The host-supplied string.
    public let rawValue: String

    /// Creates an identifier, throwing ``DownloadError/invalidIdentifier(_:)`` when the
    /// string breaks the rules above.
    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw DownloadError.invalidIdentifier(rawValue) }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid download identifier")
        }
        self.rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: DownloadID, rhs: DownloadID) -> Bool { lhs.rawValue < rhs.rawValue }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// The host's statement of which content an item represents.
///
/// Two requests for the same ``DownloadID`` describe the same content only when their
/// revisions (and optional expected length and checksum) match. A different revision for
/// an existing item is a conflict, never a silent overwrite: remove the item first, then
/// enqueue the new revision.
public struct ContentRevision: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The host-supplied revision string, for example an episode version or a content hash.
    /// An empty string means the host does not version this content.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// A revision for content the host does not version.
    public static let unversioned = ContentRevision("")

    public var description: String { rawValue }
}

/// A host-provided checksum the completed file must match.
///
/// A checksum the host trusts proves the bytes are the expected ones. A checksum computed
/// without a trusted expected value is only a consistency check.
public struct ContentChecksum: Hashable, Sendable, Codable {
    /// Supported digest algorithms.
    public enum Algorithm: String, Hashable, Sendable, Codable {
        case sha256
    }

    public let algorithm: Algorithm
    /// Lowercase hexadecimal digest.
    public let hexDigest: String

    public init(algorithm: Algorithm = .sha256, hexDigest: String) {
        self.algorithm = algorithm
        self.hexDigest = hexDigest.lowercased()
    }
}
