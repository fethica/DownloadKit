//
//  IsolationTests.swift
//  DownloadKitTests
//
//  Lexical tripwires over the library sources.
//
//  What they do: flag any import other than a plain `import Foundation` in the core (an
//  indented, attributed or `@preconcurrency` import fails too), and flag the listed
//  concurrency escape hatches in both libraries regardless of spacing.
//
//  What they do not prove: they read text, not the compiled program. They cannot see through
//  macros, generated code, conditional compilation or an escape hatch spelled some other way,
//  and they say nothing about whether isolation is correct. Swift 6 language mode with
//  complete concurrency checking is the real gate; these only catch the obvious regressions.
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

    /// Every line that is an import declaration, with or without leading whitespace or
    /// attributes, exactly as written (trimmed).
    private func importDeclarations(in text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            var rest = Substring(line)
            while rest.hasPrefix("@") {
                guard let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return false }
                rest = rest[space...].drop { $0 == " " || $0 == "\t" }
            }
            return rest.hasPrefix("import ") || rest.hasPrefix("import\t")
        }
    }

    func testImportScannerSeesIndentedAndAttributedImports() {
        let text = "import Foundation\n    import Network\n@preconcurrency import Dispatch\nlet important = 1"
        XCTAssertEqual(importDeclarations(in: text), ["import Foundation", "import Network", "@preconcurrency import Dispatch"])
    }

    func testCoreImportsFoundationOnly() throws {
        for (name, text) in try sources(in: "DownloadKit") {
            let imports = importDeclarations(in: text)
            XCTAssertTrue(imports.allSatisfy { $0 == "import Foundation" }, "\(name) imports \(imports)")
        }
    }

    func testNoConcurrencyEscapeHatches() throws {
        let forbidden = ["@unchecked Sendable", "nonisolated(unsafe)", "Task.detached", "DispatchQueue", "NSLock", "@preconcurrency", "os_unfair_lock", "pthread_mutex"]
        func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        for target in ["DownloadKit", "DownloadKitUI"] {
            for (name, text) in try sources(in: target) {
                let compact = squeezed(text)
                for token in forbidden {
                    XCTAssertFalse(compact.contains(squeezed(token)), "\(target)/\(name) contains \(token)")
                }
            }
        }
    }
}
