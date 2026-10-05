import Foundation
@testable import DownloadKit

/// A finaliser that moves the captured file to its deterministic destination in the fake
/// file system, or fails or defers on demand. Like a real finaliser it is idempotent: a
/// missing staging file with a present destination counts as already renamed.
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
            let destination = request.storageRoot.appendingPathComponent(request.destination.rawValue)
            do {
                switch try await fileSystem.inspectItem(at: captured) {
                case .file(let size):
                    try await fileSystem.synchronizeFile(at: captured)
                    try await fileSystem.moveItem(at: captured, to: destination)
                    return .finalized(finalPath: request.destination, integrity: IntegrityRecord(verifiedLength: size, checksum: nil))
                case .absent:
                    guard case .file(let size) = try await fileSystem.inspectItem(at: destination) else {
                        return .failed(.storage(.other))
                    }
                    return .finalized(finalPath: request.destination, integrity: IntegrityRecord(verifiedLength: size, checksum: nil))
                }
            } catch {
                return .failed(.storage(.other))
            }
        }
    }
}
