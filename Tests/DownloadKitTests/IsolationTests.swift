//
//  IsolationTests.swift
//  DownloadKitTests
//
//  Source-level checks that the core stays independent and that no concurrency escape hatch
//  is used anywhere in the library sources.
//

import XCTest

final class IsolationTests: XCTestCase {

    private func sources(in target: String) throws -> [(name: String, text: String)] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent("Sources").appendingPathComponent(target)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(result.isEmpty, "no sources found for \(target)")
        return result
    }

    func testCoreImportsFoundationOnly() throws {
        for (name, text) in try sources(in: "DownloadKit") {
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }
            XCTAssertTrue(imports.allSatisfy { $0 == "import Foundation" }, "\(name) imports \(imports)")
        }
    }

    func testNoConcurrencyEscapeHatches() throws {
        let forbidden = ["@unchecked Sendable", "nonisolated(unsafe)", "Task.detached", "DispatchQueue", "NSLock"]
        for target in ["DownloadKit", "DownloadKitUI"] {
            for (name, text) in try sources(in: target) {
                for token in forbidden {
                    XCTAssertFalse(text.contains(token), "\(target)/\(name) contains \(token)")
                }
            }
        }
    }
}
