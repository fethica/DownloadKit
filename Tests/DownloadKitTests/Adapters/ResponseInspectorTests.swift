//
//  ResponseInspectorTests.swift
//  DownloadKitTests
//
//  Response rules for range continuations that a URLProtocol fixture cannot produce (system
//  resume data is never generated for it), plus Retry-After, media sniffing, redirects, error
//  classification and the stored event codec.
//

import Foundation
import XCTest
@testable import DownloadKit

final class ResponseInspectorTests: XCTestCase {
    private let inspector = ResponseInspector()
    private let media = mediaBytes(64)

    private func evidence(_ status: Int, _ headers: [String: String] = [:], range: String? = nil, ifRange: String? = nil, size: Int64 = 1_000, leading: Data? = nil) -> ResponseEvidence {
        var lowered: [String: String] = [:]
        for (key, value) in headers { lowered[key.lowercased()] = value }
        return ResponseEvidence(statusCode: status, headers: lowered, requestRange: range, requestIfRange: ifRange, fileSize: size, leadingBytes: leading ?? media)
    }

    private func verdict(_ evidence: ResponseEvidence) -> ResponseVerdict {
        inspector.inspect(evidence, now: referenceDate)
    }

    func testCompleteResponseIsAcceptedWithItsEvidence() {
        let result = verdict(evidence(200, ["Content-Type": "audio/MP4; codecs=mp4a", "Content-Length": "1000", "ETag": "\"v1\"", "Last-Modified": "Mon"]))
        XCTAssertEqual(result, .accept(ResponseValidators(entityTag: "\"v1\"", lastModified: "Mon", statusCode: 200, mediaType: "audio/mp4"), bytes: 1_000))
    }

    func testIgnoredRangeIsACompleteRepresentationNeverAnAppend() {
        // The request asked to continue at byte 400; the server sent the whole file instead.
        let result = verdict(evidence(200, ["Content-Length": "1000", "ETag": "\"v1\""], range: "bytes=400-", ifRange: "\"v1\""))
        XCTAssertEqual(result, .accept(ResponseValidators(entityTag: "\"v1\"", statusCode: 200), bytes: 1_000))
    }

    func testTruncatedBodyIsTransient() {
        XCTAssertEqual(verdict(evidence(200, ["Content-Length": "2000"])), .fail(.network(code: URLError.networkConnectionLost.rawValue)))
    }

    func testSolicitedPartialContentCompletingTheFileIsAccepted() {
        let result = verdict(evidence(206, ["Content-Range": "bytes 400-999/1000", "ETag": "\"v1\""], range: "bytes=400-", ifRange: "\"v1\""))
        XCTAssertEqual(result, .accept(ResponseValidators(entityTag: "\"v1\"", statusCode: 206), bytes: 1_000))
    }

    func testUnsolicitedOrMalformedPartialContentIsInvalid() {
        XCTAssertEqual(verdict(evidence(206, ["Content-Range": "bytes 0-999/1000"])), .fail(.invalidResponse))
        XCTAssertEqual(verdict(evidence(206, ["Content-Range": "bytes 400-999/*"], range: "bytes=400-")), .fail(.invalidResponse))
        XCTAssertEqual(verdict(evidence(206, [:], range: "bytes=400-")), .fail(.invalidResponse))
    }

    func testPartialContentThatCannotBeTrustedRestartsFromZero() {
        // Another representation (changed entity tag) behind a continuation.
        XCTAssertEqual(verdict(evidence(206, ["Content-Range": "bytes 400-999/1000", "ETag": "\"v2\""], range: "bytes=400-", ifRange: "\"v1\"")), .restart)
        // A range that does not reach the end, or a file that would not hold the whole representation.
        XCTAssertEqual(verdict(evidence(206, ["Content-Range": "bytes 400-799/1000"], range: "bytes=400-")), .restart)
        XCTAssertEqual(verdict(evidence(206, ["Content-Range": "bytes 400-999/1000"], range: "bytes=400-", size: 600)), .restart)
    }

    func testRangeNotSatisfiable() {
        XCTAssertEqual(verdict(evidence(416, [:], range: "bytes=1000-")), .restart)
        XCTAssertEqual(verdict(evidence(416)), .fail(.http(status: 416, retryAfter: nil)))
    }

    func testOtherStatusesFailWithTheirCode() {
        XCTAssertEqual(verdict(evidence(204)), .fail(.invalidResponse))
        XCTAssertEqual(verdict(evidence(302)), .fail(.http(status: 302, retryAfter: nil)))
        XCTAssertEqual(TransferFailure.http(status: 302, retryAfter: nil).classification, .invalidResponse)
        XCTAssertEqual(verdict(evidence(404)), .fail(.http(status: 404, retryAfter: nil)))
        XCTAssertEqual(verdict(evidence(503, ["Retry-After": "30"])), .fail(.http(status: 503, retryAfter: 30)))
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(ResponseInspector.retryAfter("120", now: referenceDate, responseDate: nil), 120)
        XCTAssertNil(ResponseInspector.retryAfter("-5", now: referenceDate, responseDate: nil))
        XCTAssertNil(ResponseInspector.retryAfter("soon", now: referenceDate, responseDate: nil))
        XCTAssertNil(ResponseInspector.retryAfter(nil, now: referenceDate, responseDate: nil))
        let date = "Wed, 21 Oct 2026 07:28:00 GMT"
        let reference = "Wed, 21 Oct 2026 07:27:00 GMT"
        XCTAssertEqual(ResponseInspector.retryAfter(date, now: referenceDate, responseDate: reference), 60)
        let now = ResponseInspector.httpDate(reference)!
        XCTAssertEqual(ResponseInspector.retryAfter(date, now: now, responseDate: nil), 60)
        XCTAssertEqual(ResponseInspector.retryAfter(reference, now: now.addingTimeInterval(100), responseDate: nil), 0, "a date in the past means now")
    }

    func testMarkupIsNeverMedia() {
        XCTAssertEqual(verdict(evidence(200, ["Content-Type": "text/html"])), .fail(.invalidResponse))
        XCTAssertEqual(verdict(evidence(200, ["Content-Type": "application/xhtml+xml"])), .fail(.invalidResponse))
        for body in ["<!DOCTYPE html><html>", "\u{FEFF}  \n<html lang=en>", "<HEAD><title>", "<body>"] {
            XCTAssertEqual(verdict(evidence(200, ["Content-Type": "audio/mpeg"], leading: Data(body.utf8))), .fail(.invalidResponse), body)
        }
        XCTAssertEqual(verdict(evidence(200, [:], size: 0)), .fail(.invalidResponse), "an empty body is not media")
        XCTAssertFalse(ResponseInspector.looksLikeMarkup(mediaBytes(512)))
    }

    func testRedirectsNeverDowngradeTransportSecurity() {
        let secure = URL(string: "https://a.example/x")!
        let plain = URL(string: "http://b.example/x")!
        XCTAssertTrue(ResponseInspector.allowsRedirect(from: secure, to: URL(string: "https://cdn.example/y")))
        XCTAssertFalse(ResponseInspector.allowsRedirect(from: secure, to: plain))
        XCTAssertTrue(ResponseInspector.allowsRedirect(from: plain, to: secure))
        XCTAssertFalse(ResponseInspector.allowsRedirect(from: secure, to: URL(string: "ftp://c.example/z")))
    }

    func testErrorClassification() {
        let policy = URLError(.notConnectedToInternet, userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.cellular.rawValue])
        let disk = NSError(domain: NSURLErrorDomain, code: URLError.cannotWriteToFile.rawValue, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        let cases: [(any Error, TransferFailure)] = [
            (URLError(.cancelled), .cancelled),
            (URLError(.timedOut), .network(code: URLError.timedOut.rawValue)),
            (URLError(.networkConnectionLost), .network(code: URLError.networkConnectionLost.rawValue)),
            (URLError(.notConnectedToInternet), .network(code: URLError.notConnectedToInternet.rawValue)),
            (policy, .policyBlocked),
            (URLError(.userAuthenticationRequired), .credentialsUnavailable),
            (disk, .storage(.diskFull)),
            (URLError(.cannotMoveFile), .storage(.other)),
            (URLError(.badServerResponse), .invalidResponse),
            (URLError(.serverCertificateUntrusted), .unknown),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .storage(.permissionDenied)),
            (NSError(domain: "elsewhere", code: 1), .unknown),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(TransferErrorClassifier.classify(error), expected, "\(error)")
        }
        XCTAssertEqual(TransferErrorClassifier.classify(policy).classification, .policyWait)
    }

    func testStoredEventsRoundTripEveryTerminalShape() throws {
        let reference = TransferTaskReference(itemID: itemID("a"), generation: 3, taskIdentifier: 8)
        let events: [TransferEvent] = [
            .finished(reference, captured: path("staging/x"), bytes: 10, validators: ResponseValidators(entityTag: "\"e\"", statusCode: 206, mediaType: "audio/mpeg")),
            .resumeDataCaptured(reference, path("staging/r")),
            .failed(reference, .network(code: -1005)),
            .failed(reference, .http(status: 503, retryAfter: 12.5)),
            .failed(reference, .storage(.fileProtection)),
            .failed(reference, .integrity),
            .failed(reference, .invalidResponse),
            .failed(reference, .cancelled),
            .failed(reference, .policyBlocked),
            .failed(reference, .credentialsUnavailable),
            .failed(reference, .unknown),
        ]
        for event in events {
            let stored = try XCTUnwrap(StoredTransferEvent(event))
            let decoded = try JSONDecoder().decode(StoredTransferEvent.self, from: JSONEncoder().encode(stored))
            XCTAssertEqual(decoded.event, event)
        }
        XCTAssertNil(StoredTransferEvent(.progress(reference, bytesWritten: 1, expectedBytes: nil)))
        XCTAssertNil(StoredTransferEvent(.waiting(reference, .connectivity)))
    }
}
