import Foundation
@testable import DownloadKit

/// A clock that only moves when the test advances it. No real sleeping.
actor ManualClock: DownloadClock {
    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]

    init(_ start: Date = referenceDate) {
        current = start
    }

    func now() -> Date { current }

    var sleeperCount: Int { sleepers.count }
    var deadlines: [Date] { sleepers.values.map(\.deadline).sorted() }

    /// Whether a sleeper waits for exactly `deadline`. Timers are told apart by their
    /// deadline, so a wait for one timer is never satisfied by another.
    func hasSleeper(until deadline: Date) -> Bool {
        sleepers.values.contains { $0.deadline == deadline }
    }

    func sleep(until deadline: Date) async throws {
        guard deadline > current else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = (deadline, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelSleeper(id) }
        }
    }

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
        let due = sleepers.filter { $0.value.deadline <= current }
        for (id, sleeper) in due {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

struct FixedJitter: RetryJitter {
    let value: Double

    func nextFraction() -> Double { value }
}
