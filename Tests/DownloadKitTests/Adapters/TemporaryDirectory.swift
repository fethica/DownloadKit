import Foundation
import XCTest

/// A unique directory under the system temporary directory, removed by ``remove()``.
struct TemporaryDirectory {
    let url: URL

    init(_ prefix: String = "downloadkit") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func appending(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }

    func remove() {
        // Restore permissions changed by a test so the tree can be deleted.
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(relative).path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Writes `data` to `url`, creating parent directories.
func writeFile(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// Deterministic bytes that do not look like text.
func mediaBytes(_ count: Int, seed: UInt8 = 7) -> Data {
    var data = Data(count: count)
    var value = seed
    for index in 0..<count {
        value = value &* 31 &+ 17
        data[index] = value
    }
    if count >= 4 { data.replaceSubrange(0..<4, with: [0x49, 0x44, 0x33, 0x04]) }
    return data
}
