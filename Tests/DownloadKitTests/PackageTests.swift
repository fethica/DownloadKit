import XCTest
@testable import DownloadKit

final class PackageTests: XCTestCase {
    func testVersionIsDeclared() {
        XCTAssertFalse(DownloadKit.version.isEmpty)
    }
}
