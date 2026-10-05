import Foundation
@testable import DownloadKit

/// A finaliser that moves the captured file into media/ in the fake file system, or fails or
/// defers on demand.
actor FakeFinalizer: DownloadFinalizing {
    enum Mode {
        case finalize
        case fail(TransferFailure)
        case deferred
    }

    private let fileSystem: FakeFileSystem
    private var mode: Mode = .finalize
    private(set) var requests: [FinalizationRequest] = []

    init(fileSystem: FakeFileSystem) {
        self.fileSystem = fileSystem
    }

    func setMode(_ mode: Mode) { self.mode = mode }

    func finalize(_ request: FinalizationRequest) async -> FinalizationResult {
        requests.append(request)
        switch mode {
        case .fail(let failure):
            return .failed(failure)
        case .deferred:
            return .deferred
        case .finalize:
            let captured = request.storageRoot.appendingPathComponent(request.stagingPath.rawValue)
            let finalPath = RelativePath.media(generation: request.generation)
            let destination = request.storageRoot.appendingPathComponent(finalPath.rawValue)
            guard let size = await fileSystem.fileSize(at: captured) else { return .failed(.storage(.other)) }
            do {
                try await fileSystem.moveItem(at: captured, to: destination)
            } catch {
                return .failed(.storage(.other))
            }
            return .finalized(finalPath: finalPath, integrity: IntegrityRecord(verifiedLength: size, checksum: nil))
        }
    }
}
