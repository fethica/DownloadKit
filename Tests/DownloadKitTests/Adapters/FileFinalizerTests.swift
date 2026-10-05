//
//  FileFinalizerTests.swift
//  DownloadKitTests
//
//  The production finaliser on the real file system: validation before any rename, the
//  interrupted-rename recovery, deadlines, cancellation and classified storage failures.
//

import CryptoKit
import Foundation
import XCTest
@testable import DownloadKit

final class FileFinalizerTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var fileSystem: LocalFileSystem!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("finalizer")
        fileSystem = LocalFileSystem(applicationSupportDirectory: directory.url)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        directory.remove()
    }

    private var root: URL { directory.url.appendingPathComponent("ns", isDirectory: true) }
    private let content = mediaBytes(700_000)
    private var digest: String { SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined() }

    private func url(_ path: RelativePath) -> URL { root.appendingPathComponent(path.rawValue) }

    private func request(
        bytes: Int64? = nil,
        expectedLength: Int64? = nil,
        checksum: ContentChecksum? = nil,
        validators: ResponseValidators? = ResponseValidators(statusCode: 200, mediaType: "audio/mpeg"),
        destination: RelativePath = path("media/item-2.mp3"),
        deadline: Date = referenceDate.addingTimeInterval(60)
    ) -> FinalizationRequest {
        FinalizationRequest(
            id: itemID("a"), generation: 2, stagingPath: path("staging/capture"), destination: destination,
            storageRoot: root, capturedBytes: bytes ?? Int64(content.count), validators: validators,
            expectedLength: expectedLength, checksum: checksum, deadline: deadline
        )
    }

    private func finalizer(_ fileSystem: any DownloadFileSystem, clock: any DownloadClock = ManualClock(), chunkSize: Int = 64 * 1024) -> FileFinalizer {
        FileFinalizer(fileSystem: fileSystem, clock: clock, chunkSize: chunkSize)
    }

    private func placeCapture(_ data: Data? = nil) throws {
        try writeFile(url(path("staging/capture")), data ?? content)
    }

    private var captureExists: Bool { FileManager.default.fileExists(atPath: url(path("staging/capture")).path) }
    private var destinationExists: Bool { FileManager.default.fileExists(atPath: url(path("media/item-2.mp3")).path) }

    func testValidFileIsRenamedOnlyAfterValidation() async throws {
        try placeCapture()
        let checksum = ContentChecksum(hexDigest: digest)
        let result = await finalizer(fileSystem).finalize(request(expectedLength: Int64(content.count), checksum: checksum))
        XCTAssertEqual(result, .finalized(finalPath: path("media/item-2.mp3"), integrity: IntegrityRecord(verifiedLength: Int64(content.count), checksum: checksum)))
        XCTAssertFalse(captureExists)
        XCTAssertEqual(try Data(contentsOf: url(path("media/item-2.mp3"))), content)
    }

    func testValidationFailuresRenameNothing() async throws {
        let html = Data("<!doctype html><html>expired</html>".utf8)
        let cases: [(String, FinalizationRequest, Data?, FinalizationResult)] = [
            ("checksum mismatch", request(checksum: ContentChecksum(hexDigest: String(repeating: "0", count: 64))), nil, .failed(.integrity)),
            ("shorter than captured", request(bytes: Int64(content.count + 1)), nil, .failed(.integrity)),
            ("not the expected length", request(expectedLength: 10), nil, .failed(.integrity)),
            ("HTML body", request(bytes: Int64(html.count)), html, .failed(.invalidResponse)),
            ("empty body", request(bytes: 0), Data(), .failed(.invalidResponse)),
            ("error status evidence", request(validators: ResponseValidators(statusCode: 404)), nil, .failed(.invalidResponse)),
            ("HTML media type evidence", request(validators: ResponseValidators(statusCode: 200, mediaType: "text/html")), nil, .failed(.invalidResponse)),
        ]
        for (name, request, data, expected) in cases {
            try placeCapture(data)
            let result = await finalizer(fileSystem).finalize(request)
            XCTAssertEqual(result, expected, name)
            XCTAssertFalse(destinationExists, "\(name): nothing was renamed")
            XCTAssertTrue(captureExists, "\(name): the finaliser leaves discarding to the manager")
        }
    }

    func testInterruptionBetweenRenameAndCommitIsRecovered() async throws {
        // The rename happened, the commit did not: nothing is left in staging.
        try writeFile(url(path("media/item-2.mp3")), content)
        let checksum = ContentChecksum(hexDigest: digest)
        let result = await finalizer(fileSystem).finalize(request(checksum: checksum))
        XCTAssertEqual(result, .finalized(finalPath: path("media/item-2.mp3"), integrity: IntegrityRecord(verifiedLength: Int64(content.count), checksum: checksum)))

        // A renamed file that does not validate is not reported as finalised.
        try writeFile(url(path("media/item-2.mp3")), mediaBytes(content.count, seed: 3))
        let corrupt = await finalizer(fileSystem).finalize(request(checksum: checksum))
        XCTAssertEqual(corrupt, .failed(.integrity))

        try FileManager.default.removeItem(at: url(path("media/item-2.mp3")))
        let gone = await finalizer(fileSystem).finalize(request())
        XCTAssertEqual(gone, .failed(.storage(.other)), "neither file exists: the bytes are gone")
    }

    func testAnEarlierCompletedFileIsNeverOverwritten() async throws {
        let earlier = mediaBytes(1_000, seed: 5)
        try writeFile(url(path("media/item-1")), earlier)
        try placeCapture()
        let result = await finalizer(fileSystem).finalize(request())
        guard case .finalized(let finalPath, _) = result else { return XCTFail("\(result)") }
        XCTAssertNotEqual(finalPath, path("media/item-1"))
        XCTAssertEqual(try Data(contentsOf: url(path("media/item-1"))), earlier)
    }

    func testDeadlineAndCancellationDefer() async throws {
        try placeCapture()
        let late = await finalizer(fileSystem).finalize(request(deadline: referenceDate))
        XCTAssertEqual(late, .deferred)

        // The deadline passes while hashing: every clock read moves time by one second.
        let midway = await finalizer(fileSystem, clock: SteppingClock(step: 1), chunkSize: 64 * 1024)
            .finalize(request(checksum: ContentChecksum(hexDigest: digest), deadline: referenceDate.addingTimeInterval(4)))
        XCTAssertEqual(midway, .deferred)
        XCTAssertFalse(destinationExists)
        XCTAssertTrue(captureExists, "a deferred capture keeps its bytes")

        let fileSystem = self.fileSystem!
        let finalizer = self.finalizer(fileSystem)
        let request = self.request()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await finalizer.finalize(request)
        }
        let result = await cancelled.value
        XCTAssertEqual(result, .deferred)
        XCTAssertFalse(destinationExists)
    }

    func testStorageFailuresAreClassified() async throws {
        let cases: [(FaultyFileSystem.Operation, DownloadFileSystemError.Kind, FinalizationResult)] = [
            (.synchronize, .diskFull, .failed(.storage(.diskFull))),
            (.move, .permissionDenied, .failed(.storage(.permissionDenied))),
            (.read, .fileProtection, .deferred),
            (.inspect, .fileProtection, .deferred),
            (.move, .crossVolume, .failed(.storage(.other))),
        ]
        for (operation, kind, expected) in cases {
            try placeCapture()
            let faulty = FaultyFileSystem(base: fileSystem)
            await faulty.fail(operation, with: kind)
            let result = await finalizer(faulty).finalize(request())
            XCTAssertEqual(result, expected, "\(operation) \(kind)")
            XCTAssertTrue(captureExists)
            XCTAssertFalse(destinationExists)
        }
    }

    func testFinalNamesUseAllowlistedExtensionsOnly() {
        let source = URL(string: "https://media.example.com/a/episode.M4A?sig=1")!
        XCTAssertEqual(MediaFileExtension.infer(mediaType: "audio/mpeg", sourceURL: source), "mp3")
        XCTAssertEqual(MediaFileExtension.infer(mediaType: "application/octet-stream", sourceURL: source), "m4a")
        XCTAssertEqual(MediaFileExtension.infer(mediaType: nil, sourceURL: URL(string: "https://x.example/download.php")!), nil)
        XCTAssertEqual(MediaFileExtension.infer(mediaType: nil, sourceURL: URL(string: "https://x.example/a.mp3%2F..%2Fescape")!), nil)
        XCTAssertEqual(RelativePath.media(generation: 4, fileExtension: "mp3").rawValue, "media/item-4.mp3")
        XCTAssertEqual(RelativePath.media(generation: 4).rawValue, "media/item-4")
    }
}
