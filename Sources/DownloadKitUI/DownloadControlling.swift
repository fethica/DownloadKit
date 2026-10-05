//
//  DownloadControlling.swift
//  DownloadKitUI
//
//  The part of the manager the presentation layer talks to. It has no lifecycle requirement on
//  purpose: nothing in DownloadKitUI starts, detaches or releases a manager.
//

import Foundation
import DownloadKit

/// The commands and queries ``DownloadListModel`` sends.
///
/// ``DownloadKit/DownloadManager`` conforms. A host may wrap the manager (for example to log
/// commands) or a test may supply a fake. The protocol deliberately has no `start()` or
/// `detach()`: the presentation layer never owns the manager's lifecycle, so releasing a view
/// or a model never affects transfers.
public protocol DownloadControlling: AnyObject, Sendable {
    /// The snapshot sequence; one iteration is one subscription.
    associatedtype SnapshotSequence: AsyncSequence & Sendable where SnapshotSequence.Element == [DownloadSnapshot]

    func snapshots() async -> SnapshotSequence
    func pause(_ id: DownloadID) async throws
    func resume(_ id: DownloadID) async throws
    func cancel(_ id: DownloadID) async throws
    func retry(_ id: DownloadID) async throws
    func remove(_ ids: [DownloadID]) async throws
    func defaultPolicy() async -> NetworkPolicy
    func setDefaultPolicy(_ policy: NetworkPolicy) async throws
    func reconciliationStatus() async -> ReconciliationStatus
    func localFile(for id: DownloadID) async throws -> LocalFileResult
    func endAccess(_ lease: LocalFileLease) async
}

extension DownloadManager: DownloadControlling {}
