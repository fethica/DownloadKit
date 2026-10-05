//
//  DownloadStringsTests.swift
//  DownloadKitUITests
//
//  Strings, accessibility texts and redaction of displayed diagnostics.
//

import XCTest
import DownloadKit
@testable import DownloadKitUI

final class DownloadStringsTests: XCTestCase {
    private let strings = DownloadStrings.standard

    func testEveryKeyHasAnEnglishValue() {
        for key in DownloadStringKey.allCases {
            let value = strings.text(key)
            XCTAssertNotEqual(value, key.rawValue, "\(key.rawValue) has no value")
            XCTAssertFalse(value.isEmpty, key.rawValue)
            if key.rawValue.hasSuffix(".format") {
                XCTAssertTrue(value.contains("%@") || value.contains("$@"), "\(key.rawValue) takes an argument")
            } else {
                XCTAssertFalse(value.contains("%@"), "\(key.rawValue) is not a format")
            }
        }
    }

    func testCustomLookupWinsAndFallsBack() {
        let custom = DownloadStrings { key in key == "status.queued" ? "In line" : nil }
        XCTAssertEqual(custom.text(.statusQueued), "In line")
        XCTAssertEqual(custom.text(.statusCompleted), "Downloaded")
        XCTAssertEqual(custom.status(.queued), "In line")
    }

    func testEveryIndicatorHasADistinctSpokenStatus() {
        let retry = Date(timeIntervalSince1970: 0)
        let indicators: [DownloadIndicator] = [
            .notDownloaded, .queued, .active(progress: nil), .active(progress: 0.42),
            .waiting(.networkPolicy, progress: nil), .waiting(.connectivity, progress: nil),
            .waiting(.retryScheduled(at: retry), progress: nil), .waiting(.system, progress: nil),
            .waiting(.unknown, progress: nil), .paused(resumable: true, progress: nil),
            .paused(resumable: true, progress: 0.5), .paused(resumable: false, progress: 0.5),
            .failed(DownloadFailure(kind: .network)), .completed, .removing, .missing,
        ]
        let texts = indicators.map(strings.status)
        XCTAssertEqual(Set(texts).count, texts.count, "\(texts)")
        XCTAssertTrue(strings.status(.active(progress: 0.42)).contains("42"))
        XCTAssertFalse(texts.contains { $0.localizedCaseInsensitiveContains("wi-fi") }, "no claim of Wi-Fi")
    }

    func testEveryFailureKindHasAReason() {
        var seen: Set<String> = []
        for kind in DownloadFailure.Kind.allCases {
            let text = strings.failure(DownloadFailure(kind: kind, httpStatus: kind == .http ? 503 : nil))
            XCTAssertFalse(text.isEmpty)
            seen.insert(text)
        }
        XCTAssertEqual(seen.count, DownloadFailure.Kind.allCases.count)
        XCTAssertTrue(strings.failure(DownloadFailure(kind: .http, httpStatus: 503)).contains("503"))
    }

    func testActionLabelsNameTheItemAndHintsExist() {
        for action in DownloadAction.allCases {
            XCTAssertTrue(strings.label(action, itemTitle: "Tone A").contains("Tone A"), action.rawValue)
            XCTAssertFalse(strings.hint(action).isEmpty)
            XCTAssertFalse(strings.title(action).isEmpty)
        }
        for reason in [DownloadCommandFailure.Reason.notStarted, .other, .fileAccessFailed] {
            XCTAssertFalse(strings.message(reason).isEmpty)
        }
    }

    func testByteLineNeedsATotalForTheOfForm() {
        let known = DownloadItem(snapshot: snapshot("a", .active, bytes: 5_000_000, expected: 10_000_000))
        XCTAssertEqual(strings.bytes(known)?.components(separatedBy: " of ").count, 2)
        let unknown = DownloadItem(snapshot: snapshot("a", .active, bytes: 5_000_000))
        XCTAssertFalse(strings.bytes(unknown)?.contains(" of ") ?? true)
        let queued = DownloadItem(snapshot: snapshot("a", .queued, expected: 10))
        XCTAssertNil(strings.bytes(queued))
    }

    func testRedactionRemovesURLsAndPaths() {
        let text = "GET https://cdn.example.com/a.m4a?token=abc&sig=1 failed; moved file:///var/mobile/Containers/Data/x/a.wav to /private/var/mobile/y, see http://192.168.1.20:8080/files/tone.wav)"
        let redacted = DiagnosticRedaction.redact(text)
        XCTAssertFalse(redacted.contains("cdn.example.com"))
        XCTAssertFalse(redacted.contains("token"))
        XCTAssertFalse(redacted.contains("Containers"))
        XCTAssertFalse(redacted.contains("/private"))
        XCTAssertFalse(redacted.contains("192.168"))
        XCTAssertTrue(redacted.hasPrefix("GET https://[redacted] failed; moved file://[redacted] to [redacted], see http://[redacted])"), redacted)
        XCTAssertEqual(DiagnosticRedaction.redact("wake handler called, 3 events"), "wake handler called, 3 events")
        XCTAssertEqual(DiagnosticRedaction.redact("ratio 1/2 and a/b"), "ratio 1/2 and a/b")
    }
}
