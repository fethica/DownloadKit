//
//  LocalFileSystemTests.swift
//  DownloadKitTests
//

import CryptoKit
import Foundation
import XCTest
@testable import DownloadKit

final class LocalFileSystemTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var fileSystem: LocalFileSystem!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("filesystem")
        fileSystem = LocalFileSystem(applicationSupportDirectory: directory.appending("Application Support"))
    }

    override func tearDown() {
        directory.remove()
    }

    private var base: URL { directory.appending("Application Support") }

    func testBaseDirectoriesAndBackupExclusion() async throws {
        let resolved = try await fileSystem.applicationSupportDirectory()
        XCTAssertEqual(resolved.path, base.standardizedFileURL.path)
        let media = base.appendingPathComponent("ns/media", isDirectory: true)
        try await fileSystem.createDirectory(at: media)
        try await fileSystem.createDirectory(at: media)
        try await fileSystem.setExcludedFromBackup(true, at: media)

        let excluded = try media.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
        let root = try base.appendingPathComponent("ns").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(root, false)
    }

    func testInspectionSeparatesAbsenceFromFailure() async throws {
        let file = base.appendingPathComponent("ns/staging/a")
        let absent = try await fileSystem.inspectItem(at: file)
        XCTAssertEqual(absent, .absent)
        try writeFile(file, mediaBytes(1_234))
        let present = try await fileSystem.inspectItem(at: file)
        XCTAssertEqual(present, .file(size: 1_234))

        // A directory that cannot be searched: the inspection fails, it is not an absence.
        let locked = base.appendingPathComponent("ns/locked")
        try writeFile(locked.appendingPathComponent("b"), mediaBytes(10))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try await fileSystem.inspectItem(at: locked.appendingPathComponent("b"))
            XCTFail("an unreadable location was reported as a status")
        } catch let error as DownloadFileSystemError {
            XCTAssertEqual(error.kind, .permissionDenied)
        }

        do {
            _ = try await fileSystem.inspectItem(at: base.appendingPathComponent("ns/staging"))
            XCTFail("a directory was reported as a file")
        } catch let error as DownloadFileSystemError {
            XCTAssertEqual(error.kind, .notARegularFile)
        }
    }

    func testPathsOutsideTheBaseOrThroughSymbolicLinksAreRefused() async throws {
        let outside = directory.appending("outside")
        try writeFile(outside.appendingPathComponent("secret"), mediaBytes(4))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("ns"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("ns/link"), withDestinationURL: outside)

        let escapes: [URL] = [
            base.appendingPathComponent("ns/../../outside/secret"),
            outside.appendingPathComponent("secret"),
            base.appendingPathComponent("ns/link/secret"),
            base.appendingPathComponent("ns/link"),
        ]
        for url in escapes {
            do {
                _ = try await fileSystem.inspectItem(at: url)
                XCTFail("\(url.path) was inspected")
            } catch let error as DownloadFileSystemError {
                XCTAssertEqual(error.kind, .escapesRoot, url.path)
            }
            do {
                try await fileSystem.removeItem(at: url)
                XCTFail("\(url.path) was removed")
            } catch let error as DownloadFileSystemError {
                XCTAssertEqual(error.kind, .escapesRoot, url.path)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret").path), "nothing outside was touched")
    }

    func testChunkedReadsAndHashing() async throws {
        let file = base.appendingPathComponent("ns/staging/a")
        let data = mediaBytes(ContentHasher.chunkSize * 2 + 17)
        try writeFile(file, data)

        let middle = try await fileSystem.readBytes(at: file, offset: 100, maximumLength: 50)
        XCTAssertEqual(middle, data.subdata(in: 100..<150))
        let tail = try await fileSystem.readBytes(at: file, offset: Int64(data.count - 5), maximumLength: 50)
        XCTAssertEqual(tail.count, 5)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let digest = try await ContentHasher.sha256(of: file, fileSystem: fileSystem, shouldContinue: { true })
        XCTAssertEqual(digest, expected)

        let small = base.appendingPathComponent("ns/staging/abc")
        try writeFile(small, Data("abc".utf8))
        let known = try await ContentHasher.sha256(of: small, fileSystem: fileSystem, chunkSize: 2, shouldContinue: { true })
        XCTAssertEqual(known, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let interrupted = try await ContentHasher.sha256(of: file, fileSystem: fileSystem, shouldContinue: { false })
        XCTAssertNil(interrupted)
    }

    func testRenameIsAtomicAndReplacesTheDestination() async throws {
        let staging = base.appendingPathComponent("ns/staging/a")
        let media = base.appendingPathComponent("ns/media/item-1")
        try writeFile(staging, mediaBytes(30, seed: 1))
        try writeFile(media, mediaBytes(10, seed: 2))
        try await fileSystem.synchronizeFile(at: staging)

        try await fileSystem.moveItem(at: staging, to: media)

        let stagingStatus = try await fileSystem.inspectItem(at: staging)
        XCTAssertEqual(stagingStatus, .absent)
        XCTAssertEqual(try Data(contentsOf: media), mediaBytes(30, seed: 1))
        let names = try await fileSystem.contentsOfDirectory(at: base.appendingPathComponent("ns/media"))
        XCTAssertEqual(names, ["item-1"])
    }

    func testRemovalOfAnAbsentFileSucceeds() async throws {
        try await fileSystem.removeItem(at: base.appendingPathComponent("ns/staging/none"))
    }

    func testDeniedWriteIsClassified() async throws {
        let staging = base.appendingPathComponent("ns/staging/a")
        try writeFile(staging, mediaBytes(30))
        let readOnly = base.appendingPathComponent("ns/media")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

        do {
            try await fileSystem.moveItem(at: staging, to: readOnly.appendingPathComponent("item-1"))
            XCTFail("a rename into a read-only directory succeeded")
        } catch let error as DownloadFileSystemError {
            XCTAssertEqual(error.kind, .permissionDenied)
            XCTAssertEqual(error.storageReason, .permissionDenied)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "the source is kept")
    }

    func testFailedDirectoryFlushAfterARenameIsReportedNotHidden() async throws {
        let staging = base.appendingPathComponent("ns/staging/a")
        try writeFile(staging, mediaBytes(30))
        // Writable and searchable but not readable: the rename succeeds, opening the directory
        // to flush it fails.
        let media = base.appendingPathComponent("ns/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: media.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: media.path) }

        do {
            try await fileSystem.moveItem(at: staging, to: media.appendingPathComponent("item-1"))
            XCTFail("a failed directory flush was reported as success")
        } catch let error as DownloadFileSystemError {
            XCTAssertEqual(error.kind, .directoryFlushFailed)
        }
        do {
            try await fileSystem.synchronizeDirectory(at: media)
            XCTFail("a failed directory flush was reported as success")
        } catch let error as DownloadFileSystemError {
            XCTAssertEqual(error.kind, .directoryFlushFailed)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: media.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("item-1").path), "the renamed file is in place")
        try await fileSystem.synchronizeDirectory(at: media)
    }

    func testErrorClassification() {
        let cases: [(any Error, DownloadFileSystemError.Kind)] = [
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .diskFull),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .diskFull),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT)), .diskFull),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), .permissionDenied),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .permissionDenied),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]), .fileProtection),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), .notFound),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)), .crossVolume),
            (NSError(domain: NSURLErrorDomain, code: -1), .other),
        ]
        for (error, kind) in cases {
            XCTAssertEqual(DownloadFileSystemError(error).kind, kind, "\(error)")
        }
        XCTAssertEqual(DownloadFileSystemError(kind: .fileProtection).storageReason, .fileProtection)
        XCTAssertEqual(DownloadFileSystemError(kind: .diskFull).storageReason, .diskFull)
    }
}
