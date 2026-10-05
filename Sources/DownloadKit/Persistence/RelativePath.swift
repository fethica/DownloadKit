//
//  RelativePath.swift
//  DownloadKit
//

import Foundation

/// A path relative to the storage root, as stored in the index.
///
/// Rules: non-empty, `/`-separated, no leading `/` or `~`, no empty, `.` or `..` component,
/// no backslash or NUL. Decoding a stored path re-checks these rules, so a tampered index
/// cannot point outside the root.
///
/// File names are derived from internal generation counters and random staging names, never
/// from item identifiers, URL paths or server-provided names.
public struct RelativePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw DownloadError.invalidRelativePath(rawValue) }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsafe relative path")
        }
        self.rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The final location for the file completed by attempt `generation`.
    static func media(generation: UInt64) -> RelativePath {
        RelativePath(unchecked: "\(StorageLayout.mediaDirectory)/item-\(generation)")
    }

    /// A unique staging location.
    static func staging(_ name: UUID = UUID()) -> RelativePath {
        RelativePath(unchecked: "\(StorageLayout.stagingDirectory)/\(name.uuidString.lowercased())")
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~"),
              !value.contains("\\"), !value.contains("\0") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
