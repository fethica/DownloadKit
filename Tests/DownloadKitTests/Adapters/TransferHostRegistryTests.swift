import XCTest
@testable import DownloadKit

/// The registry is an actor and therefore reentrant: `invalidateAll` must claim its hosts before
/// its first suspension, so a host created for a new identifier meanwhile is not swept away and
/// a claimed identifier is refused at once.
final class TransferHostRegistryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAHostCreatedDuringInvalidationSurvivesItAndClaimedIdentifiersAreRefused() async throws {
        let registry = TransferHostRegistry()
        let options = URLSessionTransport.Options()
        let rootA = try root(), rootB = try root()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let idA = "registry-a-\(UUID().uuidString)", idB = "registry-b-\(UUID().uuidString)"
        _ = try await registry.host(for: idA, storageRoot: rootA, options: options)

        let invalidation = Task { await registry.invalidateAll(cancellingTasks: true) }
        // The claim is synchronous at the start of the operation: A leaves the registry before
        // its invalidation has finished.
        var polls = 0
        while await registry.existing(idA) != nil, polls < 10_000 { polls += 1; await Task.yield() }
        let claimed = await registry.existing(idA)
        XCTAssertNil(claimed, "the claimed host is gone from the registry at once")

        let b = try await registry.host(for: idB, storageRoot: rootB, options: options)
        await invalidation.value
        let survivor = await registry.existing(idB)
        XCTAssertTrue(survivor === b, "a host created while an older one was being invalidated is not part of that invalidation")

        do {
            _ = try await registry.host(for: idA, storageRoot: rootA, options: options)
            XCTFail("a claimed identifier is refused after invalidation")
        } catch {}
        _ = try await registry.host(for: idB, storageRoot: rootB, options: options)
        await registry.invalidateAll(cancellingTasks: true)
    }
}
