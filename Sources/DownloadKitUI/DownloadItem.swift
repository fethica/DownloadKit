//
//  DownloadItem.swift
//  DownloadKitUI
//
//  Presentation values derived from snapshots. Progress and byte counts are quantised so that
//  a view only changes when something a person can see changed.
//

import Foundation
import DownloadKit

/// What a download control shows for one item.
public enum DownloadIndicator: Hashable, Sendable {
    /// No record exists.
    case notDownloaded
    /// Handed to the system; no bytes yet.
    case queued
    /// Receiving bytes. `progress` is `nil` when the total size is unknown (indeterminate).
    case active(progress: Double?)
    /// Not progressing, with the reason the package reported.
    case waiting(WaitReason, progress: Double?)
    /// Paused by the person. `resumable` is false when the next attempt starts from zero.
    case paused(resumable: Bool, progress: Double?)
    /// Stopped with a typed failure.
    case failed(DownloadFailure)
    /// Validated and available offline.
    case completed
    /// Being removed.
    case removing
    /// The record exists but its completed file is gone.
    case missing

    /// Maps a core state. `progress` is the snapshot's fraction, already quantised.
    public init(state: DownloadState, progress: Double?) {
        switch state {
        case .notDownloaded: self = .notDownloaded
        case .queued: self = .queued
        case .active: self = .active(progress: progress)
        case .waiting(let reason): self = .waiting(reason, progress: progress)
        case .paused(let resumable): self = .paused(resumable: resumable, progress: progress)
        case .failed(let failure): self = .failed(failure)
        case .completed: self = .completed
        case .removing: self = .removing
        case .missing: self = .missing
        }
    }

    /// The determinate fraction shown, if any.
    public var progress: Double? {
        switch self {
        case .active(let progress), .waiting(_, let progress), .paused(_, let progress): return progress
        case .completed: return 1
        case .notDownloaded, .queued, .failed, .removing, .missing: return nil
        }
    }

    /// The commands that make sense in this state, most important first.
    public var actions: [DownloadAction] {
        switch self {
        case .notDownloaded, .removing: return []
        case .queued, .active: return [.pause, .cancel, .remove]
        case .waiting(let reason, _):
            if case .retryScheduled = reason { return [.retry, .pause, .cancel, .remove] }
            return [.pause, .cancel, .remove]
        case .paused: return [.resume, .cancel, .remove]
        case .failed, .missing: return [.retry, .remove]
        case .completed: return [.remove]
        }
    }

    /// The command a single tap performs, if any. A completed item has none: removing is
    /// destructive and is only offered as a secondary, confirmed action.
    public var primaryAction: DownloadAction? {
        switch self {
        case .completed: return nil
        default: return actions.first
        }
    }
}

/// A command a person can send for one item.
public enum DownloadAction: String, Hashable, Sendable, CaseIterable, Identifiable {
    case pause
    case resume
    case cancel
    case retry
    case remove

    public var id: String { rawValue }

    /// Whether the action deletes something and needs a confirmation.
    public var isDestructive: Bool { self == .remove }
}

/// One row of a downloads list.
public struct DownloadItem: Identifiable, Hashable, Sendable {
    public let id: DownloadID
    /// The metadata title, or the identifier when the host gave none.
    public let title: String
    public let subtitle: String?
    /// The metadata group, used for sections.
    public let group: String?
    public let indicator: DownloadIndicator
    /// Bytes received, rounded down to the presentation step.
    public let receivedBytes: Int64
    /// Total bytes, when known.
    public let expectedBytes: Int64?
    public let automaticRetryCount: Int

    /// Builds the presentation of `snapshot`.
    ///
    /// - Parameters:
    ///   - progressStep: progress is rounded down to a multiple of this fraction (default 1%).
    ///   - byteStep: received bytes are rounded down to a multiple of this many bytes, or of
    ///     `progressStep` of the total when the total is known and larger.
    public init(snapshot: DownloadSnapshot, progressStep: Double = 0.01, byteStep: Int64 = 65_536) {
        id = snapshot.id
        let title = snapshot.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? snapshot.id.rawValue : title
        subtitle = snapshot.metadata.subtitle
        group = snapshot.metadata.group
        let quantised = snapshot.progress.map { Self.quantise($0, step: progressStep) }
        indicator = DownloadIndicator(state: snapshot.state, progress: quantised)
        expectedBytes = snapshot.expectedBytes
        var step = max(1, byteStep)
        if let expected = snapshot.expectedBytes, expected > 0, progressStep > 0 {
            step = max(step, Int64(Double(expected) * progressStep))
        }
        receivedBytes = snapshot.bytesWritten == snapshot.expectedBytes ? snapshot.bytesWritten : (snapshot.bytesWritten / step) * step
        automaticRetryCount = snapshot.automaticRetryCount
    }

    static func quantise(_ value: Double, step: Double) -> Double {
        guard step > 0, step < 1 else { return value }
        if value >= 1 { return 1 }
        return (value / step).rounded(.down) * step
    }
}

/// Items that share a metadata group.
public struct DownloadSection: Identifiable, Hashable, Sendable {
    /// The group key, or `nil` for items without a group.
    public let group: String?
    public let items: [DownloadItem]

    public var id: String { group.map { "group:" + $0 } ?? "ungrouped" }

    /// Groups `items` by ``DownloadItem/group``, keeping the order in which each group first
    /// appears and the order of items inside it.
    public static func grouping(_ items: [DownloadItem]) -> [DownloadSection] {
        var order: [String?] = []
        var members: [String?: [DownloadItem]] = [:]
        for item in items {
            if members[item.group] == nil { order.append(item.group) }
            members[item.group, default: []].append(item)
        }
        return order.map { DownloadSection(group: $0, items: members[$0] ?? []) }
    }
}

/// What the reconciliation banner shows. `nil` from ``init(status:)`` means nothing to show.
public enum DownloadBanner: Hashable, Sendable {
    /// Start-up reconciliation is still waiting for the transfer session.
    case restoring
    /// Reconciliation could not prove what happened to these items; their intent and bytes
    /// are kept.
    case unresolved(count: Int)
    /// The transfer session could not read or store its durable backlog.
    case storageFailed(count: Int)
    /// The manager could not start.
    case startFailed(DownloadCommandFailure.Reason)

    public init?(status: ReconciliationStatus) {
        switch status {
        case .notStarted, .resolved:
            return nil
        case .awaitingBacklog:
            self = .restoring
        case .unresolved(let items, let reason):
            switch reason {
            case .sessionStorageFailed: self = .storageFailed(count: items.count)
            case .deadlineExceeded, .sessionEnded: self = .unresolved(count: items.count)
            }
        }
    }
}

/// A command that did not go through.
public struct DownloadCommandFailure: Identifiable, Hashable, Sendable {
    /// Why, in terms a person can act on. Raw error payloads (identifiers, paths, URLs) are
    /// never kept, so nothing sensitive reaches the screen.
    public enum Reason: String, Hashable, Sendable {
        case notStarted
        case itemBeingRemoved
        case unknownItem
        case conflictingRequest
        case persistenceFailed
        case reconciliationUnresolved
        case storageUnavailable
        case unsupportedIndex
        case fileAccessFailed
        case anotherOwner
        case other

        public init(_ error: any Error) {
            guard let error = error as? DownloadError else { self = .other; return }
            switch error {
            case .notStarted: self = .notStarted
            case .itemBeingRemoved: self = .itemBeingRemoved
            case .unknownItem: self = .unknownItem
            case .conflictingRequest: self = .conflictingRequest
            case .persistenceFailed: self = .persistenceFailed
            case .reconciliationUnresolved: self = .reconciliationUnresolved
            case .storageUnavailable: self = .storageUnavailable
            case .unsupportedSchema, .corruptIndex: self = .unsupportedIndex
            case .fileAccessFailed: self = .fileAccessFailed
            case .ownerAlreadyActive, .alreadyStarted: self = .anotherOwner
            default: self = .other
            }
        }
    }

    public let id: UUID
    public let action: DownloadAction?
    public let itemID: DownloadID?
    public let reason: Reason

    public init(action: DownloadAction?, itemID: DownloadID?, reason: Reason) {
        self.id = UUID()
        self.action = action
        self.itemID = itemID
        self.reason = reason
    }
}

/// A removal waiting for the person's confirmation.
public struct DownloadRemovalRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The explicit members to remove; files are never removed by group or pattern.
    public let ids: [DownloadID]
    /// The item title for one item, or the group name for several.
    public let title: String?

    public init(ids: [DownloadID], title: String?) {
        self.id = UUID()
        self.ids = ids
        self.title = title
    }
}

/// The result of ``DownloadListModel/openLocalFile(for:)``.
public enum LocalFileAccess: Hashable, Sendable {
    /// A validated completed file. End the lease with ``DownloadListModel/endAccess(_:)``.
    case available(LocalFileLease)
    /// No usable completed file; nothing was fetched.
    case unavailable(LocalFileUnavailableReason)
    /// The file exists but could not be inspected (for example file protection while the
    /// device is locked). Nothing changed.
    case accessFailed
    /// The lookup failed for another reason.
    case failed(DownloadCommandFailure.Reason)
}

/// The network choices offered by ``NetworkPolicyPicker``.
public enum NetworkPolicyChoice: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// No cellular, no expensive networks, waits in Low Data Mode. The package default.
    case unmeteredOnly
    /// No cellular or expensive networks, but Low Data Mode is allowed.
    case unmeteredIncludingLowData
    /// Any network, cellular included.
    case anyNetwork

    public var id: String { rawValue }

    /// The policy, keeping `scheduling`.
    public func policy(scheduling: NetworkPolicy.Scheduling = .userInitiated) -> NetworkPolicy {
        switch self {
        case .unmeteredOnly: return NetworkPolicy(allowsCellular: false, allowsExpensive: false, allowsConstrained: false, scheduling: scheduling)
        case .unmeteredIncludingLowData: return NetworkPolicy(allowsCellular: false, allowsExpensive: false, allowsConstrained: true, scheduling: scheduling)
        case .anyNetwork: return NetworkPolicy(allowsCellular: true, allowsExpensive: true, allowsConstrained: true, scheduling: scheduling)
        }
    }

    /// The choice matching `policy`'s network flags, or `nil` for a custom combination.
    public init?(policy: NetworkPolicy) {
        guard let match = Self.allCases.first(where: { $0.policy(scheduling: policy.scheduling) == policy }) else { return nil }
        self = match
    }
}
