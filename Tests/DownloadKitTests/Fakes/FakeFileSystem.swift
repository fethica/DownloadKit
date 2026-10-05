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

    init() {
        applicationSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fake-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    func configure(failApplicationSupport: Bool = false, failCreateDirectory: Bool = false, failRemove: Bool = false) {
        self.failApplicationSupport = failApplicationSupport
        self.failCreateDirectory = failCreateDirectory
        self.failRemove = failRemove
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

    func fileSize(at url: URL) -> Int64? {
        files[Self.key(url)]
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
