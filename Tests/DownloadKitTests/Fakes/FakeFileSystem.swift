import Foundation
@testable import DownloadKit

/// An in-memory file system with fault injection. Nothing touches the disk.
actor FakeFileSystem: DownloadFileSystem {
    nonisolated let applicationSupport: URL

    private(set) var directories: Set<String> = []
    private(set) var excludedFromBackup: Set<String> = []
    private(set) var files: [String: Int64] = [:]
    private(set) var removed: [String] = []
    private var failApplicationSupport = false
    private var failCreateDirectory = false
    private var failRemove = false
    private var failInspection = false

    init() {
        applicationSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fake-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    func configure(failApplicationSupport: Bool = false, failCreateDirectory: Bool = false, failRemove: Bool = false, failInspection: Bool = false) {
        self.failApplicationSupport = failApplicationSupport
        self.failCreateDirectory = failCreateDirectory
        self.failRemove = failRemove
        self.failInspection = failInspection
    }

    func putFile(_ url: URL, size: Int64) {
        files[Self.key(url)] = size
    }

    func hasFile(_ url: URL) -> Bool {
        files[Self.key(url)] != nil
    }

    func isDirectory(_ url: URL) -> Bool {
        directories.contains(Self.key(url))
    }

    func isExcluded(_ url: URL) -> Bool {
        excludedFromBackup.contains(Self.key(url))
    }

    func applicationSupportDirectory() throws -> URL {
        if failApplicationSupport { throw FakeError.injected }
        return applicationSupport
    }

    func createDirectory(at url: URL) throws {
        if failCreateDirectory { throw FakeError.injected }
        directories.insert(Self.key(url))
    }

    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        if excluded { excludedFromBackup.insert(Self.key(url)) } else { excludedFromBackup.remove(Self.key(url)) }
    }

    func inspectItem(at url: URL) throws -> FileStatus {
        if failInspection { throw FakeError.injected }
        guard let size = files[Self.key(url)] else { return .absent }
        return .file(size: size)
    }

    func contentsOfDirectory(at url: URL) throws -> [String] {
        let prefix = Self.key(url) + "/"
        return files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    func readBytes(at url: URL, offset: Int64, maximumLength: Int) throws -> Data {
        guard let size = files[Self.key(url)] else { throw FakeError.injected }
        let available = max(0, size - offset)
        return Data(count: Int(min(Int64(maximumLength), available)))
    }

    func synchronizeFile(at url: URL) throws {
        guard files[Self.key(url)] != nil else { throw FakeError.injected }
    }

    func removeItem(at url: URL) throws {
        if failRemove { throw FakeError.injected }
        files[Self.key(url)] = nil
        removed.append(Self.key(url))
    }

    func moveItem(at source: URL, to destination: URL) throws {
        guard let size = files.removeValue(forKey: Self.key(source)) else { throw FakeError.injected }
        files[Self.key(destination)] = size
    }

    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
