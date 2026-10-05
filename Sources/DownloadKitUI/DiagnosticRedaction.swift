//
//  DiagnosticRedaction.swift
//  DownloadKitUI
//
//  Diagnostics shown on screen (an event log, an error detail) must not reveal where content
//  comes from or where it lives: signed URLs carry credentials in their query, and absolute
//  paths name the device's container.
//

import Foundation

/// Removes URLs and absolute file paths from text before it is displayed.
public enum DiagnosticRedaction {
    /// The text that replaces what was removed.
    public static let placeholder = "[redacted]"

    /// `text` with every `scheme://...` URL reduced to its scheme and every absolute path
    /// under a system or user directory replaced. For example
    /// `"GET https://cdn.example.com/a.m4a?token=x failed"` becomes
    /// `"GET https://[redacted] failed"`.
    public static func redact(_ text: String) -> String {
        var result = text
        for (pattern, template) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static let rules: [(String, String)] = [
        // Any URL with a scheme, up to whitespace or a quote; trailing punctuation is kept.
        (#"\b([A-Za-z][A-Za-z0-9+.\-]*)://(?:[^\s"'<>]*[^\s"'<>.,;:!?)\]])?"#, "$1://" + placeholder),
        // Absolute paths under the usual roots, including sandbox containers.
        (#"(?<![\w:/])/(?:Users|var|private|Volumes|System|Library|Applications|tmp|home|mnt)\b(?:[^\s"'<>]*[^\s"'<>.,;:!?)\]])?"#, placeholder),
    ]
}
