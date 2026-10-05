//
//  NetworkPathSource.swift
//  DownloadKit
//

import Foundation

/// Observes the current network path, for honest wait reasons only.
///
/// Path observation explains why items wait and lets the manager resubmit an attempt that
/// ended on a policy refusal. It is never proof that a request will succeed, and it cannot
/// enforce policy while the app is suspended. The production `NWPathMonitor` adapter is not
/// implemented yet.
public protocol NetworkPathSource: Sendable {
    func currentStatus() async -> NetworkPathStatus?
    var updates: AsyncStream<NetworkPathStatus> { get }
}
