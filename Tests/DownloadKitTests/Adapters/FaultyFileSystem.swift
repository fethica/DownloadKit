import Foundation
@testable import DownloadKit

/// The real file system with injected, classified failures per operation: full disk, denied
/// write, file protection.
actor FaultyFileSystem: DownloadFileSystem {
    enum Operation: Hashable {
        case inspect, read, synchronize, move, remove, list
    }

    private let base: LocalFileSystem
    private var faults: [Operation: DownloadFileSystemError] = [:]
    private(set) var calls: [Operation] = []

    init(base: LocalFileSystem) {
        self.base = base
    }

    func fail(_ operation: Operation, with kind: DownloadFileSystemError.Kind?) {
        faults[operation] = kind.map { DownloadFileSystemError(kind: $0) }
    }

    private func check(_ operation: Operation) throws {
        calls.append(operation)
        if let fault = faults[operation] { throw fault }
    }

    func applicationSupportDirectory() async throws -> URL { try await base.applicationSupportDirectory() }
    func createDirectory(at url: URL) async throws { try await base.createDirectory(at: url) }
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) async throws { try await base.setExcludedFromBackup(excluded, at: url) }

    func inspectItem(at url: URL) async throws -> FileStatus {
        try check(.inspect)
        return try await base.inspectItem(at: url)
    }

    func contentsOfDirectory(at url: URL) async throws -> [String] {
        try check(.list)
        return try await base.contentsOfDirectory(at: url)
    }

    func readBytes(at url: URL, offset: Int64, maximumLength: Int) async throws -> Data {
        try check(.read)
        return try await base.readBytes(at: url, offset: offset, maximumLength: maximumLength)
    }

    func synchronizeFile(at url: URL) async throws {
        try check(.synchronize)
        try await base.synchronizeFile(at: url)
    }

    func removeItem(at url: URL) async throws {
        try check(.remove)
        try await base.removeItem(at: url)
    }

    func moveItem(at source: URL, to destination: URL) async throws {
        try check(.move)
        try await base.moveItem(at: source, to: destination)
    }
}

/// A clock that moves forward by `step` every time it is read.
actor SteppingClock: DownloadClock {
    private var current: Date
    private let step: TimeInterval

    init(start: Date = referenceDate, step: TimeInterval) {
        current = start
        self.step = step
    }

    func now() -> Date {
        defer { current = current.addingTimeInterval(step) }
        return current
    }

    func sleep(until deadline: Date) async throws {}
}
