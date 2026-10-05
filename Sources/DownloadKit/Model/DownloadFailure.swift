//
//  DownloadFailure.swift
//  DownloadKit
//

import Foundation

/// A persisted, typed failure attached to a ``DownloadState/failed(_:)`` item.
public struct DownloadFailure: Hashable, Sendable, Codable {
    /// Stable failure keys. The raw values are persisted and must never be renamed once
    /// shipped.
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case unknown
        case network
        case http
        case storageFull = "storage_full"
        case storage
        case fileProtection = "file_protection"
        case integrity
        case unauthorized
        case invalidResponse = "invalid_response"
        case cancelled
    }

    public var kind: Kind
    /// The HTTP status code, for HTTP-derived failures.
    public var httpStatus: Int?

    public init(kind: Kind, httpStatus: Int? = nil) {
        self.kind = kind
        self.httpStatus = httpStatus
    }
}

/// How a transfer failure is handled.
public enum FailureClass: Hashable, Sendable {
    /// Connection loss, timeouts and selected 5xx/429 responses. Retried automatically with
    /// bounded backoff.
    case networkTransient
    /// A 4xx/5xx response that will not change by retrying.
    case permanentHTTP
    /// 401/403 or an expired signed URL. The host may refresh the URL on user retry.
    case authentication
    /// Disk full, permission or file-protection errors.
    case storage
    /// The bytes did not match the expected length or checksum.
    case integrity
    /// A response that is not usable media (for example an HTML body served as success).
    case invalidResponse
    /// The transfer was cancelled.
    case cancelled
    /// The current network is not allowed by policy. Waits; spends no retry attempt.
    case policyWait
    /// Anything else.
    case unknown
}

/// Why a storage operation failed.
public enum StorageFailureReason: String, Hashable, Sendable, Codable {
    case diskFull
    case permissionDenied
    case fileProtection
    case other
}

/// A failure reported by a transfer session or the finaliser.
public enum TransferFailure: Error, Hashable, Sendable {
    /// A transport-level error (for example a `URLError` code).
    case network(code: Int?)
    /// An unsuccessful HTTP status, with the server's Retry-After in seconds when present.
    case http(status: Int, retryAfter: TimeInterval?)
    case storage(StorageFailureReason)
    case integrity
    case invalidResponse
    case cancelled
    /// The request was refused because the current network is not allowed by policy.
    case policyBlocked
    /// The host could not provide a transfer URL for the attempt (see
    /// ``URLRefreshing/transferURL(for:sourceURL:metadata:)``).
    case credentialsUnavailable
    case unknown

    /// The handling class of this failure.
    public var classification: FailureClass {
        switch self {
        case .network:
            return .networkTransient
        case .http(let status, _):
            if status == 401 || status == 403 { return .authentication }
            if Self.transientStatuses.contains(status) { return .networkTransient }
            if (400...599).contains(status) { return .permanentHTTP }
            return .invalidResponse
        case .storage:
            return .storage
        case .integrity:
            return .integrity
        case .invalidResponse:
            return .invalidResponse
        case .cancelled:
            return .cancelled
        case .policyBlocked:
            return .policyWait
        case .credentialsUnavailable:
            return .authentication
        case .unknown:
            return .unknown
        }
    }

    /// The server-provided Retry-After delay, if any.
    public var retryAfter: TimeInterval? {
        if case .http(_, let retryAfter) = self { return retryAfter }
        return nil
    }

    /// The persisted failure recorded when this failure ends an attempt.
    public var downloadFailure: DownloadFailure {
        switch self {
        case .network:
            return DownloadFailure(kind: .network)
        case .http(let status, _):
            switch classification {
            case .authentication: return DownloadFailure(kind: .unauthorized, httpStatus: status)
            case .invalidResponse: return DownloadFailure(kind: .invalidResponse, httpStatus: status)
            default: return DownloadFailure(kind: .http, httpStatus: status)
            }
        case .storage(let reason):
            switch reason {
            case .diskFull: return DownloadFailure(kind: .storageFull)
            case .fileProtection: return DownloadFailure(kind: .fileProtection)
            case .permissionDenied, .other: return DownloadFailure(kind: .storage)
            }
        case .integrity:
            return DownloadFailure(kind: .integrity)
        case .invalidResponse:
            return DownloadFailure(kind: .invalidResponse)
        case .cancelled:
            return DownloadFailure(kind: .cancelled)
        case .credentialsUnavailable:
            return DownloadFailure(kind: .unauthorized)
        case .policyBlocked, .unknown:
            return DownloadFailure(kind: .unknown)
        }
    }

    private static let transientStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
}
