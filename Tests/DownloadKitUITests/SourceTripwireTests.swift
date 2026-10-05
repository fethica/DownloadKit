//
//  SourceTripwireTests.swift
//  DownloadKitUITests
//
//  Lexical checks that the presentation product stays a presentation product: it imports only
//  SwiftUI, Foundation and the core, never a player or media framework, and the core target
//  declares no dependency. Like the core tripwires, these read text and prove nothing about
//  the compiled program beyond what they match.
//

import XCTest

final class SourceTripwireTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPresentationImportsNoPlayerOrMediaFramework() throws {
        let directory = packageRoot.appendingPathComponent("Sources/DownloadKitUI")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var files = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let imports = text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") || $0.hasPrefix("@") && $0.contains(" import ") }
            for line in imports {
                XCTAssertTrue(["import SwiftUI", "import Foundation", "import DownloadKit"].contains(line), "\(url.lastPathComponent): \(line)")
            }
        }
        XCTAssertGreaterThan(files, 5)
    }

    func testCoreTargetDeclaresNoDependency() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let squeezed = manifest.filter { !$0.isWhitespace }
        XCTAssertTrue(squeezed.contains(#".target(name:"DownloadKit",dependencies:[])"#), "the core target has no dependency")
        XCTAssertTrue(squeezed.contains(#"dependencies:[],targets"#), "the package has no external dependency")
    }
}
