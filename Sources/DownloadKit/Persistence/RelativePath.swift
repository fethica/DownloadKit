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

    /// The final location for the file completed by attempt `generation`, with an extension
    /// from ``MediaFileExtension`` when one is known.
    static func media(generation: UInt64, fileExtension: String? = nil) -> RelativePath {
        let suffix = fileExtension.map { ".\($0)" } ?? ""
        return RelativePath(unchecked: "\(StorageLayout.mediaDirectory)/item-\(generation)\(suffix)")
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

/// The extension of a completed file, so a player that infers the format from the file name
/// can open it. Only values from fixed allowlists are used: the response's declared media type
/// first, then the source URL's extension. Never a server-provided file name.
enum MediaFileExtension {
    private static let byMediaType: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3",
        "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a",
        "audio/aac": "aac", "audio/x-aac": "aac", "audio/aacp": "aac",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/vnd.wave": "wav",
        "audio/aiff": "aiff", "audio/x-aiff": "aiff", "audio/x-caf": "caf",
        "audio/flac": "flac", "audio/x-flac": "flac", "audio/ogg": "ogg",
        "audio/webm": "webm", "video/webm": "webm",
        "video/mp4": "mp4", "video/x-m4v": "m4v", "video/quicktime": "mov",
    ]

    private static let sourceExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "oga", "webm", "mp4", "m4v", "mov",
    ]

    static func infer(mediaType: String?, sourceURL: URL) -> String? {
        if let mediaType, let known = byMediaType[mediaType.lowercased()] { return known }
        let candidate = sourceURL.pathExtension.lowercased()
        return sourceExtensions.contains(candidate) ? candidate : nil
    }
}
