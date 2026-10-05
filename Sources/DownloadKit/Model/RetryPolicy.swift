//
//  RetryPolicy.swift
//  DownloadKit
//

import Foundation

/// Bounded automatic retries for transient failures.
///
/// Only ``FailureClass/networkTransient`` failures are retried automatically. Policy waits
/// spend no attempt. A user ``DownloadManager/retry(_:)`` resets the count. Retries are
/// application-level attempts; retries the system performs inside one transfer are not
/// observable and not counted.
public struct RetryPolicy: Hashable, Sendable {
    /// Automatic retries after the initial attempt.
    public var maximumAutomaticRetries: Int
    /// Delay before the first retry, before jitter.
    public var baseDelay: TimeInterval
    /// Upper bound of the exponential delay.
    public var maximumDelay: TimeInterval
    /// Upper bound applied to a server's Retry-After.
    public var maximumRetryAfter: TimeInterval

    public init(maximumAutomaticRetries: Int = 3, baseDelay: TimeInterval = 2, maximumDelay: TimeInterval = 300, maximumRetryAfter: TimeInterval = 3600) {
        self.maximumAutomaticRetries = max(0, maximumAutomaticRetries)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(0, maximumDelay)
        self.maximumRetryAfter = max(0, maximumRetryAfter)
    }

    public static let `default` = RetryPolicy()

    /// The delay before retry number `retryIndex` (zero-based).
    ///
    /// `min(maximumDelay, baseDelay * 2^retryIndex)` scaled into `[50%, 100%]` by `jitter`
    /// (clamped to `0...1`). A Retry-After value raises the delay to at least that value,
    /// capped at ``maximumRetryAfter``.
    public func delay(forRetry retryIndex: Int, jitter: Double, retryAfter: TimeInterval?) -> TimeInterval {
        let exponent = Double(max(0, min(retryIndex, 30)))
        let exponential = min(maximumDelay, baseDelay * pow(2, exponent))
        let clampedJitter = min(1, max(0, jitter))
        let jittered = exponential * (0.5 + 0.5 * clampedJitter)
        guard let retryAfter, retryAfter > 0 else { return jittered }
        return min(maximumRetryAfter, max(retryAfter, jittered))
    }
}
