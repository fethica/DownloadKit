//
//  ExternalAdapterTests.swift
//  DownloadKitPublicAPITests
//
//  Compiles against the public surface only (no testable import): an index store, a
//  transfer session and a file system written outside the module must be implementable.
//

import Foundation
import XCTest
import DownloadKit

/// A row-style store that rebuilds records from individual fields.
actor RowStore: DownloadIndexStore {
    private var contents: IndexContents?

    func load() -> IndexContents? { contents }

    func apply(_ changes: IndexChangeSet) {
        let rebuilt = changes.upserts.compactMap { record in
            try? IndexRecord(
                id: record.id, request: RequestIdentity(sourceURL: record.request.sourceURL, revision: record.request.revision, expectedLength: record.request.expectedLength, checksum: record.request.checksum),
                metadata: record.metadata, policy: record.policy, phase: record.phase, generation: record.generation,
                automaticRetryCount: record.automaticRetryCount, retryAt: record.retryAt, binding: record.binding,
                stoppingBinding: record.stoppingBinding, bytesWritten: record.bytesWritten, expectedBytes: record.expectedBytes,
                validators: record.validators, integrity: record.integrity, journal: record.journal, stagingPath: record.stagingPath,
                finalizationDestination: record.finalizationDestination, finalPath: record.finalPath, resumeDataPath: record.resumeDataPath, createdAt: record.createdAt, updatedAt: record.updatedAt
            )
        }
        contents = IndexChangeSet(
            upserts: rebuilt, deletions: changes.deletions, nextGeneration: changes.nextGeneration, defaultPolicy: changes.defaultPolicy,
            cleanupQueued: changes.cleanupQueued, cleanupCompleted: changes.cleanupCompleted
        ).applied(to: contents)
    }
}

/// A session that knows no tasks, written against the public protocol.
struct EmptySession: TransferSession {
    let identifier = "external.session"
    let events: AsyncStream<TransferSessionEvent> = AsyncStream { continuation in
        continuation.yield(TransferSessionEvent(sequence: 1, payload: .backlogDelivered))
    }
    func submit(_ submission: TransferSubmission) async throws -> Int { throw TransferFailure.unknown }
    func cancel(taskIdentifier: Int, producingResumeData: Bool) async {}
    func systemTasks() async -> [SystemTransferTask] { [SystemTransferTask(taskIdentifier: 1, taskDescription: nil)] }
    func acknowledge(through sequence: UInt64) async {}
}

/// A file system that finds nothing, written against the public protocol.
struct EmptyFileSystem: DownloadFileSystem {
    func applicationSupportDirectory() async throws -> URL { URL(fileURLWithPath: "/nonexistent") }
    func createDirectory(at url: URL) async throws {}
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) async throws {}
    func inspectItem(at url: URL) async throws -> FileStatus { .absent }
    func contentsOfDirectory(at url: URL) async throws -> [String] { [] }
    func readBytes(at url: URL, offset: Int64, maximumLength: Int) async throws -> Data { Data() }
    func synchronizeFile(at url: URL) async throws {}
    func removeItem(at url: URL) async throws {}
    func moveItem(at source: URL, to destination: URL) async throws {}
}

final class ExternalAdapterTests: XCTestCase {

    private func record(binding: TaskBinding?, generation: UInt64 = 3) throws -> IndexRecord {
        try IndexRecord(
            id: DownloadID("episode-1"),
            request: RequestIdentity(sourceURL: URL(string: "https://media.example.com/episode-1.m4a")!, revision: ContentRevision("r1"), expectedLength: 10, checksum: nil),
            metadata: DownloadMetadata(title: "Episode 1"),
            policy: nil,
            phase: .paused,
            generation: generation,
            automaticRetryCount: 0,
            retryAt: nil,
            binding: binding,
            stoppingBinding: TaskBinding(sessionIdentifier: "external.session", taskIdentifier: 4, generation: generation),
            bytesWritten: 5,
            expectedBytes: 10,
            validators: ResponseValidators(entityTag: "\"v1\""),
            integrity: nil,
            journal: .notStarted,
            stagingPath: nil,
            finalPath: nil,
            resumeDataPath: try RelativePath("staging/resume"),
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func testRecordsRoundTripThroughAnExternalRowStore() async throws {
        let stored = try record(binding: nil)
        let store = RowStore()

        await store.apply(IndexChangeSet(upserts: [stored], nextGeneration: 4))

        let loaded = await store.load()
        XCTAssertEqual(loaded?.records, [stored])
        XCTAssertEqual(loaded?.nextGeneration, 4)
    }

    func testContradictoryStoredFieldsAreRejected() throws {
        let future = TaskBinding(sessionIdentifier: "external.session", taskIdentifier: 1, generation: 9)
        XCTAssertThrowsError(try record(binding: future)) { error in
            XCTAssertEqual(error as? DownloadError, .invalidStoredRecord(try! DownloadID("episode-1")))
        }
    }

    func testExternalAdaptersSatisfyThePorts() async throws {
        let session = EmptySession()
        let tasks = await session.systemTasks()
        XCTAssertNil(tasks.first?.reference, "a task without a package description is unmapped")
        let status = try await EmptyFileSystem().inspectItem(at: URL(fileURLWithPath: "/nonexistent/file"))
        XCTAssertEqual(status, .absent)
    }
}
