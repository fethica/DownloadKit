//
//  RetryJitter.swift
//  DownloadKit
//

import Foundation

/// The source of retry jitter.
public protocol RetryJitter: Sendable {
    /// A value in `0..<1`.
    func nextFraction() async -> Double
}

/// Uniform random jitter from the system generator.
public struct SystemJitter: RetryJitter {
    public init() {}

    public func nextFraction() -> Double { Double.random(in: 0..<1) }
}
