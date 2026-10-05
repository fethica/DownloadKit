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

    /// Where a finalisation suspends until ``release()``, like a worker preempted mid-way.
    enum Gate {
        case none
        case beforeRename
        case afterRename
    }

    private let fileSystem: FakeFileSystem
    private var mode: Mode = .finalize
    private var gate: Gate = .none
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [FinalizationRequest] = []

    init(fileSystem: FakeFileSystem) {
        self.fileSystem = fileSystem
    }

    func setMode(_ mode: Mode) { self.mode = mode }
    func setGate(_ gate: Gate) { self.gate = gate }

    /// Finalisations currently suspended at the gate.
    var suspendedCount: Int { suspended.count }

    /// Resumes every suspended finalisation and stops gating.
    func release() {
        gate = .none
        let waiting = suspended
        suspended = []
        for continuation in waiting { continuation.resume() }
    }

    private func pause(at point: Gate) async {
        guard gate == point else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspended.append(continuation)
        }
    }

    func finalize(_ request: FinalizationRequest) async -> FinalizationResult {
        requests.append(request)
        await pause(at: .beforeRename)
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
                    await pause(at: .afterRename)
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
