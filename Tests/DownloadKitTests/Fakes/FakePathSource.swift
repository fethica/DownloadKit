import Foundation
@testable import DownloadKit

actor FakePathSource: NetworkPathSource {
    nonisolated let updates: AsyncStream<NetworkPathStatus>
    private nonisolated let continuation: AsyncStream<NetworkPathStatus>.Continuation
    private var status: NetworkPathStatus?

    init(_ status: NetworkPathStatus?) {
        self.status = status
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathStatus.self)
        self.updates = stream
        self.continuation = continuation
    }

    func currentStatus() -> NetworkPathStatus? { status }

    func publish(_ status: NetworkPathStatus) {
        self.status = status
        continuation.yield(status)
    }
}
