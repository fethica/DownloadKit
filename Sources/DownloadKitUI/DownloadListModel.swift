//
//  DownloadListModel.swift
//  DownloadKitUI
//
//  Optional SwiftUI presentation over the DownloadKit core. The model owns no transfers:
//  dropping it, or the view that holds it, never cancels a download and never detaches the
//  manager.
//

import SwiftUI
import DownloadKit

/// A main-actor model of the downloads list for SwiftUI views.
///
/// Observe the manager for as long as a view is on screen:
///
/// ```swift
/// @StateObject private var downloads = DownloadListModel(controller: manager)
///
/// var body: some View {
///     DownloadList(model: downloads)
///         .task { await downloads.observe() }
/// }
/// ```
///
/// `observe()` is one snapshot subscription. It returns when its task is cancelled (SwiftUI
/// cancels `.task` when the view disappears) or when the stream ends, and the subscription
/// ends with it. Neither affects transfers, and the manager keeps running. The model holds the
/// manager strongly but never starts, detaches or releases it.
///
/// Each list that arrives also refreshes the manager-wide values, ``banner`` (from the
/// reconciliation status) and ``defaultPolicy``: the manager delivers a list when one of them
/// changes even if no item did, so a policy set elsewhere in the app or a reconciliation that
/// times out or resolves quietly shows up without an explicit refresh.
///
/// Publishing is bounded twice: the manager's stream delivers at most one list per
/// ``DownloadKit/DownloadConfiguration/snapshotInterval`` and keeps only the newest, and the
/// model publishes only when the presentation changed (progress is rounded to
/// `progressStep`, bytes to `byteStep`).
@available(iOS 15, macOS 12, *)
@MainActor
public final class DownloadListModel: ObservableObject {
    /// The rows, in the manager's order (oldest item first).
    @Published public private(set) var items: [DownloadItem] = []
    /// What the reconciliation banner shows, or `nil`.
    @Published public private(set) var banner: DownloadBanner?
    /// The manager's default policy, once loaded.
    @Published public private(set) var defaultPolicy: NetworkPolicy?
    /// Items with a command in flight. Their controls are disabled so a burst of taps sends
    /// one command.
    @Published public private(set) var busyItems: Set<DownloadID> = []
    /// The last command that did not go through. Set it to `nil` to dismiss it.
    @Published public var lastFailure: DownloadCommandFailure?
    /// A removal waiting for confirmation (see ``requestRemoval(of:title:)``).
    @Published public var pendingRemoval: DownloadRemovalRequest?
    /// Whether at least one ``observe()`` call is running.
    @Published public private(set) var isObserving = false
    /// The lease held for playback by ``beginPlayback(of:)``, or `nil`. It becomes `nil` when
    /// playback ends, including when the item is removed; stop the player when it does.
    @Published public private(set) var playbackLease: LocalFileLease?

    /// The latest raw snapshots. Not published on its own: views should read ``items``.
    public private(set) var snapshots: [DownloadSnapshot] = []

    private let controller: (any DownloadControlling)?
    private let progressStep: Double
    private let byteStep: Int64
    private var observations = 0
    private var startFailure: DownloadCommandFailure.Reason?
    private var leases: [LocalFileLease] = []
    /// Advanced by every playback request and stop; a lookup that finishes under an older
    /// value is obsolete and its lease is ended at once.
    private var playbackToken: UInt64 = 0
    /// Advances whenever a policy write starts, so a policy read begun before the write cannot
    /// overwrite the written value when its continuation lands afterwards.
    private(set) var policyRevision: UInt64 = 0
    /// The playback lookup in flight (item and request token), so that the removal of its
    /// item can supersede it.
    private var pendingPlayback: (id: DownloadID, token: UInt64)?

    /// Creates a model for `controller`, usually the app's ``DownloadKit/DownloadManager``.
    public init(controller: any DownloadControlling, progressStep: Double = 0.01, byteStep: Int64 = 65_536) {
        self.controller = controller
        self.progressStep = progressStep
        self.byteStep = byteStep
    }

    /// Creates a model without a manager, fed only through ``apply(_:)``. Commands report
    /// ``DownloadCommandFailure/Reason/notStarted``.
    public init() {
        self.controller = nil
        self.progressStep = 0.01
        self.byteStep = 65_536
    }

    // MARK: Observation

    /// Subscribes to the manager's snapshots until the calling task is cancelled or the stream
    /// ends. Call it from `.task`. Several concurrent calls are allowed; each is its own
    /// subscription.
    public func observe() async {
        guard let controller else { return }
        observations += 1
        isObserving = true
        defer {
            observations -= 1
            isObserving = observations > 0
        }
        await refreshDefaultPolicy()
        await Self.pump(controller, into: self)
    }

    /// Iterates outside the main actor and hops back for each list, so the iterator never
    /// crosses an isolation boundary.
    private nonisolated static func pump<C: DownloadControlling>(_ controller: C, into model: DownloadListModel) async {
        let sequence = await controller.snapshots()
        do {
            for try await list in sequence {
                if Task.isCancelled { break }
                let status = await controller.reconciliationStatus()
                let revision = await model.policyRevision
                let policy = await controller.defaultPolicy()
                await model.receive(list, status: status, policy: policy, policyRevision: revision)
            }
        } catch {
            // A throwing sequence ended; the subscription is over either way.
        }
    }

    /// Replaces the list with `snapshots`, publishing only when the presentation changed.
    public func apply(_ snapshots: [DownloadSnapshot]) {
        self.snapshots = snapshots
        let items = snapshots.map { DownloadItem(snapshot: $0, progressStep: progressStep, byteStep: byteStep) }
        if items != self.items { self.items = items }
    }

    func receive(_ snapshots: [DownloadSnapshot], status: ReconciliationStatus, policy: NetworkPolicy? = nil, policyRevision: UInt64? = nil) {
        apply(snapshots)
        updateBanner(DownloadBanner(status: status))
        if let policy, policyRevision ?? self.policyRevision == self.policyRevision, policy != defaultPolicy { defaultPolicy = policy }
        endPlaybackIfRemoved(by: snapshots)
    }

    private func updateBanner(_ fromStatus: DownloadBanner?) {
        let banner = startFailure.map(DownloadBanner.startFailed) ?? fromStatus
        if banner != self.banner { self.banner = banner }
    }

    /// Shows a start failure in the banner until ``clearStartFailure()``. The model never
    /// starts the manager itself; the host reports what its `start()` threw.
    public func reportStartFailure(_ error: any Error) {
        startFailure = DownloadCommandFailure.Reason(error)
        updateBanner(nil)
    }

    public func clearStartFailure() {
        startFailure = nil
        updateBanner(nil)
    }

    /// Reads the reconciliation status once, for example after a pull to refresh.
    public func refreshStatus() async {
        guard let controller else { return }
        updateBanner(DownloadBanner(status: await controller.reconciliationStatus()))
    }

    // MARK: Lookup

    public func item(for id: DownloadID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    public func snapshot(for id: DownloadID) -> DownloadSnapshot? {
        snapshots.first { $0.id == id }
    }

    /// ``items`` grouped by metadata group.
    public var sections: [DownloadSection] {
        DownloadSection.grouping(items)
    }

    // MARK: Commands

    /// Sends `action` for `id`. ``DownloadAction/remove`` only asks for confirmation (see
    /// ``requestRemoval(of:title:)``); the other actions run at once. A second command for an
    /// item whose command is still in flight is ignored.
    public func perform(_ action: DownloadAction, on id: DownloadID) async {
        if action == .remove {
            requestRemoval(of: [id], title: item(for: id)?.title)
            return
        }
        await run(action, ids: [id]) { controller in
            switch action {
            case .pause: try await controller.pause(id)
            case .resume: try await controller.resume(id)
            case .cancel: try await controller.cancel(id)
            case .retry: try await controller.retry(id)
            case .remove: break
            }
        }
    }

    /// Asks for confirmation before removing the explicit members `ids`.
    public func requestRemoval(of ids: [DownloadID], title: String?) {
        guard !ids.isEmpty else { return }
        pendingRemoval = DownloadRemovalRequest(ids: ids, title: title)
    }

    /// Removes the members of ``pendingRemoval``.
    public func confirmRemoval() async {
        guard let request = pendingRemoval else { return }
        pendingRemoval = nil
        var removed = false
        await run(.remove, ids: request.ids) { controller in
            try await controller.remove(request.ids)
            removed = true
        }
        // The removal waits for leases; the playback lease of a removed item is ended here so
        // the removal can finish, and a playback lookup still in flight for a removed item is
        // made obsolete, so the lease it returns is ended instead of installed.
        if removed, let pending = pendingPlayback, request.ids.contains(pending.id) {
            playbackToken &+= 1
        }
        if removed, let lease = playbackLease, request.ids.contains(lease.id) {
            await releasePlaybackLease()
        }
    }

    public func cancelRemoval() {
        pendingRemoval = nil
    }

    /// The identifiers of every item in `group`.
    public func members(of group: String?) -> [DownloadID] {
        items.filter { $0.group == group }.map(\.id)
    }

    private func run(_ action: DownloadAction, ids: [DownloadID], _ body: (any DownloadControlling) async throws -> Void) async {
        guard let controller else {
            lastFailure = DownloadCommandFailure(action: action, itemID: ids.first, reason: .notStarted)
            return
        }
        guard busyItems.isDisjoint(with: ids) else { return }
        busyItems.formUnion(ids)
        defer { busyItems.subtract(ids) }
        do {
            try await body(controller)
        } catch {
            lastFailure = DownloadCommandFailure(action: action, itemID: ids.count == 1 ? ids.first : nil, reason: .init(error))
        }
    }

    // MARK: Network policy

    /// The choice matching ``defaultPolicy``, or `nil` for a custom policy or before loading.
    public var policyChoice: NetworkPolicyChoice? {
        defaultPolicy.flatMap(NetworkPolicyChoice.init(policy:))
    }

    public func refreshDefaultPolicy() async {
        guard let controller else { return }
        let revision = policyRevision
        let policy = await controller.defaultPolicy()
        // A write that started meanwhile owns the value; this read is stale.
        guard revision == policyRevision else { return }
        if policy != defaultPolicy { defaultPolicy = policy }
    }

    /// Persists `choice` as the default policy, keeping the current scheduling.
    public func setDefaultPolicy(_ choice: NetworkPolicyChoice) async {
        guard let controller else {
            lastFailure = DownloadCommandFailure(action: nil, itemID: nil, reason: .notStarted)
            return
        }
        let policy = choice.policy(scheduling: defaultPolicy?.scheduling ?? .userInitiated)
        policyRevision &+= 1
        do {
            try await controller.setDefaultPolicy(policy)
            defaultPolicy = policy
        } catch {
            lastFailure = DownloadCommandFailure(action: nil, itemID: nil, reason: .init(error))
        }
    }

    // MARK: Local files

    /// Leases handed out by ``openLocalFile(for:)`` and not yet ended.
    public var openLeases: [LocalFileLease] { leases }

    /// Resolves a validated completed file. Nothing is fetched from the network. An available
    /// file comes with a lease that keeps it on disk (a removal waits for it): end it with
    /// ``endAccess(_:)`` when playback stops. Leases are not ended when a view disappears,
    /// because playback may outlive the view; ``endAllAccess()`` ends every lease this model
    /// handed out.
    public func openLocalFile(for id: DownloadID) async -> LocalFileAccess {
        guard let controller else { return .failed(.notStarted) }
        do {
            switch try await controller.localFile(for: id) {
            case .available(let lease):
                leases.append(lease)
                return .available(lease)
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        } catch {
            let reason = DownloadCommandFailure.Reason(error)
            return reason == .fileAccessFailed ? .accessFailed : .failed(reason)
        }
    }

    /// Ends `lease`. Ending a lease twice, or one this model did not hand out, is safe.
    public func endAccess(_ lease: LocalFileLease) async {
        guard let controller else { return }
        leases.removeAll { $0 == lease }
        await controller.endAccess(lease)
    }

    /// Ends every lease this model handed out, the playback lease included, and makes any
    /// playback lookup still in flight obsolete.
    public func endAllAccess() async {
        playbackToken &+= 1
        playbackLease = nil
        let open = leases
        leases.removeAll()
        guard let controller else { return }
        for lease in open { await controller.endAccess(lease) }
    }

    // MARK: Playback

    /// Resolves `id`'s validated local file for playback and holds its lease as
    /// ``playbackLease``, the only playback lease of this model.
    ///
    /// The previous playback lease is ended first, whatever item it was for. The newest call
    /// wins: a call overtaken by a later ``beginPlayback(of:)`` or ``endPlayback()`` while its
    /// lookup was in flight returns `nil`, and the lease its lookup produced is ended at once,
    /// so a burst of taps leaves at most one lease. A `nil` result means "do nothing": a newer
    /// request owns playback. Nothing is fetched from the network.
    public func beginPlayback(of id: DownloadID) async -> LocalFileAccess? {
        playbackToken &+= 1
        let token = playbackToken
        pendingPlayback = (id, token)
        defer { if pendingPlayback?.token == token { pendingPlayback = nil } }
        await releasePlaybackLease()
        guard token == playbackToken else { return nil }
        let access = await openLocalFile(for: id)
        guard token == playbackToken else {
            if case .available(let lease) = access { await endAccess(lease) }
            return nil
        }
        if case .available(let lease) = access { playbackLease = lease }
        return access
    }

    /// Ends the playback lease, if any, and makes a playback lookup still in flight obsolete.
    /// Calling it again does nothing. Call it when the player stops or fails, and when the
    /// screen that owns playback goes away.
    public func endPlayback() async {
        playbackToken &+= 1
        await releasePlaybackLease()
    }

    private func releasePlaybackLease() async {
        guard let lease = playbackLease else { return }
        playbackLease = nil
        await endAccess(lease)
    }

    /// A playback lease on an item that is now being removed would hold the removal; it is
    /// ended. A playback lookup still in flight for an item being removed is made obsolete,
    /// so the lease it returns is ended instead of installed. While a lease is held no
    /// playback lookup is in flight (each one releases the lease first), so no newer request
    /// is overtaken here.
    private func endPlaybackIfRemoved(by snapshots: [DownloadSnapshot]) {
        if let pending = pendingPlayback,
           snapshots.contains(where: { $0.id == pending.id && $0.state == .removing }) {
            playbackToken &+= 1
        }
        guard let lease = playbackLease,
              snapshots.contains(where: { $0.id == lease.id && $0.state == .removing }) else { return }
        playbackLease = nil
        Task { await self.endAccess(lease) }
    }
}
