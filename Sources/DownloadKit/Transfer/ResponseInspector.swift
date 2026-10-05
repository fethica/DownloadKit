//
//  ResponseInspector.swift
//  DownloadKit
//
//  Pure decisions about a finished HTTP response and a failed transfer: no I/O, every input
//  passed in, so each rule is tested directly.
//

import Foundation

/// What a finished download task showed about its response.
struct ResponseEvidence: Sendable, Equatable {
    var statusCode: Int
    /// Response headers, keys lowercased.
    var headers: [String: String]
    /// The `Range` header the request carried, when it continued earlier bytes.
    var requestRange: String?
    /// The `If-Range` header the request carried.
    var requestIfRange: String?
    /// The size of the downloaded file.
    var fileSize: Int64
    /// The first bytes of the downloaded file (at most ``ResponseInspector/sniffLength``).
    var leadingBytes: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]?.trimmingCharacters(in: .whitespaces)
    }
}

/// The inspector's decision.
enum ResponseVerdict: Sendable, Equatable {
    /// Usable media: capture it with this evidence.
    case accept(ResponseValidators, bytes: Int64)
    /// Report the attempt as failed.
    case fail(TransferFailure)
    /// The continuation of earlier bytes cannot be trusted (the server refused the range or sent
    /// another representation): start the attempt again from zero, never append.
    case restart
}

/// Decides whether a finished response is usable media.
///
/// Rules:
/// - 200 is a complete representation, whether or not a range was asked for (a server that
///   ignores a range sends the whole file; it is never appended to earlier bytes). A declared
///   `Content-Length` must match the file, otherwise the body was truncated (transient).
/// - 206 is accepted only for a request that asked for a range, with a `Content-Range` that ends
///   at the last byte of the representation, an entity tag matching the `If-Range` sent, and a
///   file that holds the whole representation. An unsolicited 206 is an invalid response; a
///   mismatch on a continuation restarts from zero.
/// - 416 on a continuation restarts from zero; without a range it is an HTTP failure.
/// - Any other status fails with its code and parsed `Retry-After`.
/// - An empty body, an HTML media type or a body that starts like an HTML document is not
///   playable media, whatever the status said.
struct ResponseInspector: Sendable {
    static let sniffLength = 512

    /// Media types that are never accepted as downloaded media.
    var rejectedMediaTypes: Set<String> = ["text/html", "application/xhtml+xml"]

    func inspect(_ evidence: ResponseEvidence, now: Date) -> ResponseVerdict {
        let status = evidence.statusCode
        switch status {
        case 200:
            if let declared = evidence.header("content-length").flatMap(Int64.init), declared != evidence.fileSize {
                return .fail(.network(code: URLError.networkConnectionLost.rawValue))
            }
        case 206:
            guard evidence.requestRange != nil,
                  let range = evidence.header("content-range").flatMap(Self.parseContentRange) else {
                return .fail(.invalidResponse)
            }
            if let ifRange = evidence.requestIfRange, Self.isEntityTag(ifRange),
               let entityTag = evidence.header("etag"), entityTag != ifRange {
                return .restart
            }
            guard range.end == range.total - 1, evidence.fileSize == range.total else { return .restart }
        case 416:
            return evidence.requestRange != nil ? .restart : .fail(.http(status: status, retryAfter: nil))
        case 200..<300:
            return .fail(.invalidResponse)
        default:
            let retryAfter = Self.retryAfter(evidence.header("retry-after"), now: now, responseDate: evidence.header("date"))
            return .fail(.http(status: status, retryAfter: retryAfter))
        }
        let mediaType = evidence.header("content-type").map(Self.mediaType)
        if let mediaType, rejectedMediaTypes.contains(mediaType) { return .fail(.invalidResponse) }
        if evidence.fileSize == 0 || Self.looksLikeMarkup(evidence.leadingBytes) { return .fail(.invalidResponse) }
        let validators = ResponseValidators(
            entityTag: evidence.header("etag"),
            lastModified: evidence.header("last-modified"),
            statusCode: status,
            mediaType: mediaType
        )
        return .accept(validators, bytes: evidence.fileSize)
    }

    /// `type/subtype`, lowercased, without parameters.
    static func mediaType(_ contentType: String) -> String {
        contentType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// Whether the body starts like an HTML document (after an optional byte order mark and
    /// whitespace).
    static func looksLikeMarkup(_ data: Data) -> Bool {
        var bytes = data.prefix(sniffLength)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        bytes = bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        let head = String(decoding: bytes.prefix(32), as: UTF8.self).lowercased()
        return ["<!doctype html", "<html", "<head", "<body"].contains { head.hasPrefix($0) }
    }

    /// `bytes <start>-<end>/<total>` with a known total.
    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, start <= end, end < total else { return nil }
        return (start, end, total)
    }

    /// Seconds to wait from a `Retry-After` value: delta seconds or an HTTP date, measured from
    /// the response's `Date` (or `now`). Never negative.
    static func retryAfter(_ value: String?, now: Date, responseDate: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? TimeInterval(seconds) : nil }
        guard let date = httpDate(value) else { return nil }
        let reference = responseDate.flatMap(httpDate) ?? now
        return max(0, date.timeIntervalSince(reference))
    }

    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func isEntityTag(_ value: String) -> Bool {
        value.hasPrefix("\"") || value.hasPrefix("W/")
    }

    /// Whether following a redirect keeps the transfer's transport security: a redirect from
    /// HTTPS to anything else is refused.
    static func allowsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let destination, let scheme = destination.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        if original?.scheme?.lowercased() == "https" { return scheme == "https" }
        return true
    }
}

/// Maps a task's completion error to a typed transfer failure.
///
/// Network loss, timeouts and unreachable hosts are transient; a request refused because the
/// network is cellular, expensive or constrained is a policy wait; authentication problems are
/// authentication failures; file errors are storage failures with their reason; malformed
/// responses are invalid responses; certificate and transport-security failures are permanent.
enum TransferErrorClassifier {
    static func classify(_ error: any Error) -> TransferFailure {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            let storage = DownloadFileSystemError(error)
            switch storage.kind {
            case .diskFull, .permissionDenied, .fileProtection: return .storage(storage.storageReason)
            default: return .unknown
            }
        }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet:
            if (error as? URLError)?.networkUnavailableReason != nil { return .policyBlocked }
            return .network(code: nsError.code)
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed,
             .backgroundSessionWasDisconnected, .cannotLoadFromNetwork, .resourceUnavailable:
            return .network(code: nsError.code)
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .credentialsUnavailable
        case .cannotCreateFile, .cannotOpenFile, .cannotCloseFile, .cannotWriteToFile, .cannotRemoveFile, .cannotMoveFile:
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                let storage = DownloadFileSystemError(underlying)
                return .storage(storage.storageReason)
            }
            return .storage(.other)
        case .badServerResponse, .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse,
             .zeroByteResource, .dataLengthExceedsMaximum, .httpTooManyRedirects, .redirectToNonExistentLocation,
             .badURL, .unsupportedURL, .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile:
            return .invalidResponse
        case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection, .backgroundSessionInUseByAnotherProcess,
             .backgroundSessionRequiresSharedContainer:
            return .unknown
        default:
            return .network(code: nsError.code)
        }
    }
}
