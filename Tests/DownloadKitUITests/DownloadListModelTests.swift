import XCTest
import Combine
import DownloadKit
@testable import DownloadKitUI

@MainActor
final class DownloadListModelTests: XCTestCase {
    func testApplyPublishesSnapshotsAndLooksUpByID() throws {
        let model = DownloadListModel()
        let id = try DownloadID("episode-1")
        let snapshot = DownloadSnapshot(
            id: id,
            revision: ContentRevision("r1"),
            metadata: DownloadMetadata(title: "Episode 1"),
            state: .active,
            bytesWritten: 25,
            expectedBytes: 100,
            automaticRetryCount: 0,
            retryAt: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        model.apply([snapshot])

        XCTAssertEqual(model.snapshots, [snapshot])
        XCTAssertEqual(model.snapshot(for: id)?.progress, 0.25)
        XCTAssertNil(model.snapshot(for: try DownloadID("other")))
    }

    func testApplyingAnEqualListDoesNotPublish() throws {
        let model = DownloadListModel()
        var publications = 0
        let cancellable = model.objectWillChange.sink { publications += 1 }
        model.apply([])
        XCTAssertEqual(publications, 0)
        cancellable.cancel()
    }
}
