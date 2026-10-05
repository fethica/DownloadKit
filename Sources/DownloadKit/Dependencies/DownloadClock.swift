//
//  DownloadClock.swift
//  DownloadKit
//

import Foundation

/// Wall-clock time and in-process waiting.
///
/// Timers built on a clock only run while the process runs. Durable retry times are stored
/// in the index and re-evaluated on the next start.
public protocol DownloadClock: Sendable {
    func now() async -> Date
    /// Suspends until `deadline`, throwing `CancellationError` when the task is cancelled.
    func sleep(until deadline: Date) async throws
}

/// The system clock.
public struct SystemClock: DownloadClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let interval = min(deadline.timeIntervalSinceNow, 86_400 * 365)
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
