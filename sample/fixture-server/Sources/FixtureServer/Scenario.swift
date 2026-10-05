//
//  Scenario.swift
//  FixtureServer
//
//  The response scenarios. A file is served with a scenario chosen by its path
//  (`/s/<scenario>/<file>`) or by an override set through the control endpoint for
//  `/files/<file>`.
//

import Foundation

enum Scenario: String, CaseIterable, Sendable {
    /// 200 with Content-Length; a single byte range is answered with 206 (If-Range honoured).
    case ok
    /// Every request, ranged or not, gets the full 200 response.
    case ignoreRange = "ignore-range"
    /// Any request with a Range header gets 416; other requests 200.
    case rangeNotSatisfiable = "range-416"
    /// Every response carries a new ETag and Last-Modified; a range is answered with 206 under
    /// the new validator, as a server whose content changed between attempts would.
    case changingETag = "changing-etag"
    /// 302 to `/files/<file>`.
    case redirect
    /// 200 without Content-Length; the body ends when the connection closes.
    case noLength = "no-length"
    /// Waits 8 seconds before the status line, then serves normally.
    case slowFirstByte = "slow-first-byte"
    /// Sends 64 KiB per second.
    case slowBody = "slow-body"
    /// Declares the full length, sends 40% of the body, then resets the connection.
    case disconnect
    /// Declares the full length, sends all but the last 1,024 bytes, then closes cleanly.
    case truncated
    /// 404.
    case notFound = "not-found"
    /// 500 with Retry-After: 3.
    case serverError = "server-error"
    /// 503 with Retry-After: 10.
    case unavailable
    /// 200 text/html with an HTML page.
    case html
    /// 200 declared as the file's media type, with an HTML sign-in page as the body.
    case htmlAsMedia = "html-as-media"
    /// 200 with the right length and one byte changed in the middle, so a checksum fails.
    case checksumMismatch = "checksum-mismatch"
    /// 403, as for an expired signed link.
    case expired
    /// 401.
    case unauthorized

    var summary: String {
        switch self {
        case .ok: return "200, ranges answered with 206"
        case .ignoreRange: return "200 even for a range request"
        case .rangeNotSatisfiable: return "416 for any range request"
        case .changingETag: return "new ETag on every response"
        case .redirect: return "302 to the plain file"
        case .noLength: return "200 without Content-Length"
        case .slowFirstByte: return "8 s before the first byte"
        case .slowBody: return "64 KiB per second"
        case .disconnect: return "connection reset after 40%"
        case .truncated: return "body 1 KiB short, clean close"
        case .notFound: return "404"
        case .serverError: return "500, Retry-After 3"
        case .unavailable: return "503, Retry-After 10"
        case .html: return "200 text/html"
        case .htmlAsMedia: return "HTML body declared as media"
        case .checksumMismatch: return "one byte changed"
        case .expired: return "403 expired link"
        case .unauthorized: return "401"
        }
    }
}

/// Per-file overrides set through the control endpoint. Shared by connection threads.
final class OverrideStore: @unchecked Sendable {
    struct Override: Sendable {
        var scenario: Scenario
        /// Requests left; `nil` means until cleared.
        var remaining: Int?
    }

    private let lock = NSLock()
    private var overrides: [String: Override] = [:]
    private var etagCounter = 0

    func set(_ scenario: Scenario, for file: String, times: Int?) {
        lock.withLock { overrides[file] = Override(scenario: scenario, remaining: times) }
    }

    func clear(_ file: String?) {
        lock.withLock {
            if let file { overrides[file] = nil } else { overrides.removeAll() }
        }
    }

    /// The scenario for the next request of `file`, consuming one use of a counted override.
    func take(for file: String) -> Scenario {
        lock.withLock {
            guard var entry = overrides[file] else { return .ok }
            if let remaining = entry.remaining {
                if remaining <= 1 { overrides[file] = nil } else { entry.remaining = remaining - 1; overrides[file] = entry }
            }
            return entry.scenario
        }
    }

    func nextETagGeneration() -> Int {
        lock.withLock { etagCounter += 1; return etagCounter }
    }

    func snapshot() -> [String: Override] {
        lock.withLock { overrides }
    }
}
