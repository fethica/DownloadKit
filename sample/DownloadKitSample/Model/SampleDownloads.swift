//
//  SampleDownloads.swift
//  DownloadKitSample
//
//  The app's one long-lived owner of the DownloadManager. Views get the list model from here;
//  they observe it while visible and never own the manager.
//

import Foundation
import DownloadKit
import DownloadKitUI

@MainActor
final class SampleDownloads: ObservableObject {
    enum StartState: Equatable {
        case starting
        case running
        case failed(DownloadCommandFailure.Reason)
    }

    let manager: DownloadManager
    let wakes: BackgroundTransferEvents
    let list: DownloadListModel
    let log: EventLog
    let server = FixtureServerClient()
    @Published private(set) var startState: StartState = .starting

    private var startTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    init(wakes: BackgroundTransferEvents, log: EventLog) {
        self.wakes = wakes
        self.log = log
        do {
            let configuration = try SampleConfiguration.makeConfiguration()
            manager = DownloadManager(configuration: configuration, urlRefresher: FixtureLinkRefresher(), backgroundEvents: wakes)
        } catch {
            // The namespace and identifier are constants; this cannot fail at run time.
            fatalError("invalid sample configuration: \(error)")
        }
        list = DownloadListModel(controller: manager)
    }

    /// Starts the manager once per process. The UI stays usable meanwhile: commands sent
    /// before start finishes are refused with a "still starting" message.
    func start() {
        guard startTask == nil else { return }
        let manager = manager
        startTask = Task {
            do {
                try await manager.start()
                startState = .running
                list.clearStartFailure()
                let status = await manager.reconciliationStatus()
                log.record("manager started, reconciliation: \(describe(status))")
                watch()
            } catch {
                let reason = DownloadCommandFailure.Reason(error)
                startState = .failed(reason)
                list.reportStartFailure(error)
                log.record("manager start failed: \(reason.rawValue)")
            }
        }
    }

    /// Logs every state change for the life of the process (progress is not logged).
    private func watch() {
        let manager = manager
        watchTask = Task { [weak self] in
            var last: [DownloadID: String] = [:]
            for await snapshots in await manager.snapshots() {
                guard let self else { return }
                for snapshot in snapshots {
                    let state = Self.describe(snapshot.state)
                    if last[snapshot.id] != state {
                        last[snapshot.id] = state
                        self.log.record("\(snapshot.id): \(state)")
                    }
                }
            }
        }
    }

    // MARK: Commands

    func enqueue(_ item: FixtureItem) async {
        guard let url = server.url(for: item.path), let plain = server.url(for: "files/\(item.file.name)") else {
            log.record("enqueue \(item.id): the fixture server address is not valid")
            return
        }
        do {
            let request = DownloadRequest(
                id: try DownloadID(item.id),
                url: url,
                revision: ContentRevision("1"),
                expectedLength: item.declaresLength ? item.file.length : nil,
                checksum: ContentChecksum(hexDigest: item.file.sha256),
                metadata: DownloadMetadata(
                    title: item.title,
                    subtitle: item.subtitle,
                    group: item.group,
                    userInfo: [FixtureLinkRefresher.refreshKey: plain.absoluteString]
                )
            )
            try await manager.enqueue(request)
            log.record("enqueue \(item.id)")
        } catch {
            let reason = DownloadCommandFailure.Reason(error)
            list.lastFailure = DownloadCommandFailure(action: nil, itemID: try? DownloadID(item.id), reason: reason)
            log.record("enqueue \(item.id) refused: \(reason.rawValue)")
        }
    }

    func flushPendingWork() async -> String {
        do {
            try await manager.flushPendingWork()
            return "Nothing pending"
        } catch {
            return "Pending: \(DownloadCommandFailure.Reason(error).rawValue)"
        }
    }

    func unreferencedFileCount() async -> String {
        do {
            return String(try await manager.unreferencedFiles().count)
        } catch {
            return DownloadCommandFailure.Reason(error).rawValue
        }
    }

    func reconciliationDescription() async -> String {
        describe(await manager.reconciliationStatus())
    }

    var pendingWakeHandlers: Int {
        wakes.pendingHandlerCount(forSession: SampleConfiguration.sessionIdentifier)
    }

    // MARK: Descriptions (no URLs, no paths)

    private func describe(_ status: ReconciliationStatus) -> String {
        switch status {
        case .notStarted: return "not started"
        case .awaitingBacklog: return "awaiting the session backlog"
        case .resolved: return "resolved"
        case .unresolved(let items, let reason): return "unresolved (\(items.count) items, \(reason.rawValue))"
        }
    }

    nonisolated static func describe(_ state: DownloadState) -> String {
        switch state {
        case .notDownloaded: return "not downloaded"
        case .queued: return "queued"
        case .active: return "active"
        case .paused(let resumable): return resumable ? "paused (resumable)" : "paused (from zero)"
        case .waiting(let reason):
            switch reason {
            case .networkPolicy: return "waiting (network policy)"
            case .connectivity: return "waiting (connectivity)"
            case .retryScheduled: return "waiting (retry scheduled)"
            case .system: return "waiting (system)"
            case .unknown: return "waiting (unknown)"
            }
        case .completed: return "completed"
        case .failed(let failure): return "failed (\(failure.kind.rawValue)\(failure.httpStatus.map { " \($0)" } ?? ""))"
        case .removing: return "removing"
        case .missing: return "missing"
        }
    }
}
