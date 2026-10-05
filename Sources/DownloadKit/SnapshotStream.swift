//
//  SnapshotStream.swift
//  DownloadKit
//

import Foundation

/// The snapshot stream returned by ``DownloadManager/snapshots()``.
///
/// Each iterator is its own subscription: it subscribes on its first `next()` and
/// unsubscribes when the iteration ends for any reason, including `break`, a thrown error,
/// task cancellation or the iterator being released, even while the stream value itself is
/// still retained. The first value is the current list, delivered immediately; it does not
/// count toward ``DownloadConfiguration/snapshotInterval``. Later values arrive at most once
/// per interval, and only the newest list is buffered. Ending a subscription never affects
/// transfers.
public struct DownloadSnapshotStream: AsyncSequence, Sendable {
    public typealias Element = [DownloadSnapshot]

    let engine: DownloadEngine

    public func makeAsyncIterator() -> Iterator {
        Iterator(engine: engine)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let engine: DownloadEngine
        private var subscription: SnapshotSubscription?
        private var base: AsyncStream<[DownloadSnapshot]>.Iterator?
        private var finished = false

        init(engine: DownloadEngine) {
            self.engine = engine
        }

        public mutating func next() async -> [DownloadSnapshot]? {
            guard !finished else { return nil }
            if base == nil {
                let (id, stream) = await engine.subscribe()
                subscription = SnapshotSubscription(engine: engine, id: id)
                base = stream.makeAsyncIterator()
            }
            let value = await base?.next()
            if value == nil || Task.isCancelled {
                finished = true
                base = nil
                subscription = nil
            }
            return value
        }
    }
}

/// Ends one subscription when the last iterator copy holding it is released.
final class SnapshotSubscription: Sendable {
    let engine: DownloadEngine
    let id: UUID

    init(engine: DownloadEngine, id: UUID) {
        self.engine = engine
        self.id = id
    }

    deinit {
        let engine = engine
        let id = id
        Task { await engine.unsubscribe(id) }
    }
}
