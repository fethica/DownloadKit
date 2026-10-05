//
//  DownloadEngine.swift
//  DownloadKit
//
//  The single source of truth for in-memory state. Every command and every event runs as one
//  step of a FIFO chain, so steps never interleave even though they suspend for persistence
//  and transport calls. Within a step the state machine decides, the index persists, and only
//  then does the in-memory state change and do effects run.
//

import Foundation

actor DownloadEngine {
    typealias Command = DownloadStateMachine.Command
    typealias Event = DownloadStateMachine.Event
    typealias Effect = DownloadStateMachine.Effect

    private enum Lifecycle: Equatable {
        case idle
        case starting
        case running
        case detached
    }

    private struct PendingRemoval {
        let generation: UInt64
        let paths: [RelativePath]
    }

    let configuration: DownloadConfiguration
    private let urlRefresher: (any URLRefreshing)?
    private let finalizer: any DownloadFinalizing

    private var lifecycle: Lifecycle = .idle
    private var machine: DownloadStateMachine?
    private var store: (any DownloadIndexStore)?
    private var session: (any TransferSession)?
    private var layout: StorageLayout?
    private var claimToken: UUID?

    private var tail: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[DownloadSnapshot]>.Continuation] = [:]
    private var leases: [DownloadID: Set<UUID>] = [:]
    private var pendingRemovals: [DownloadID: PendingRemoval] = [:]
    private var retryTimers: [DownloadID: Task<Void, Never>] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var lastEmission: Date?
    private var stateVersion: UInt64 = 0
    private var emittedVersion: UInt64 = 0

    private var dependencies: DownloadDependencies { configuration.dependencies }

    init(configuration: DownloadConfiguration, urlRefresher: (any URLRefreshing)?, finalizer: any DownloadFinalizing) {
        self.configuration = configuration
        self.urlRefresher = urlRefresher
        self.finalizer = finalizer
    }

    // MARK: Serialisation

    /// Runs `operation` after every previously submitted step has finished.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let step = Task<T, any Error> { [self] in
            await previous?.value
            do {
                let value = try await operation()
                await publishIfChanged()
                return value
            } catch {
                await publishIfChanged()
                throw error
            }
        }
        tail = Task { _ = await step.result }
        return try await step.value
    }

    private func requireRunning() throws {
        guard lifecycle == .running else { throw DownloadError.notStarted }
    }

    // MARK: Lifecycle

    func start() async throws {
        try await serialized { [self] in try await self.runStart() }
    }

    private func runStart() async throws {
        guard lifecycle == .idle else { throw DownloadError.alreadyStarted }
        lifecycle = .starting
        do {
            try await bootstrap()
            lifecycle = .running
            try await reconcile()
            startConsumers()
        } catch {
            await teardown()
            machine = nil
            store = nil
            session = nil
            layout = nil
            lifecycle = .idle
            throw error
        }
    }

    private func bootstrap() async throws {
        let fileSystem = dependencies.fileSystem
        let applicationSupport: URL
        do {
            applicationSupport = try await fileSystem.applicationSupportDirectory()
        } catch {
            throw DownloadError.storageUnavailable
        }
        let layout = StorageLayout(applicationSupport: applicationSupport, scope: configuration.storageScope)
        claimToken = try await OwnerRegistry.shared.claim(root: layout.ownerKey, session: configuration.sessionIdentifier, owner: self)

        do {
            try await fileSystem.createDirectory(at: layout.root)
            try await fileSystem.createDirectory(at: layout.media)
            try await fileSystem.createDirectory(at: layout.staging)
            try await fileSystem.setExcludedFromBackup(true, at: layout.media)
            try await fileSystem.setExcludedFromBackup(true, at: layout.staging)
        } catch {
            throw DownloadError.storageUnavailable
        }

        let store: any DownloadIndexStore
        let contents: IndexContents?
        do {
            store = try await dependencies.makeIndexStore(layout.root)
            contents = try await store.load()
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.corruptIndex
        }
        if let contents {
            guard contents.schemaVersion <= IndexSchema.currentVersion else {
                throw DownloadError.unsupportedSchema(found: contents.schemaVersion, supported: IndexSchema.currentVersion)
            }
            guard contents.schemaVersion >= 1 else { throw DownloadError.corruptIndex }
        }

        let session: any TransferSession
        do {
            session = try await dependencies.transport.makeSession(identifier: configuration.sessionIdentifier, storageRoot: layout.root)
        } catch {
            throw DownloadError.transportUnavailable
        }

        self.layout = layout
        self.store = store
        self.session = session
        self.machine = DownloadStateMachine(
            contents: contents,
            sessionIdentifier: configuration.sessionIdentifier,
            defaultPolicy: configuration.defaultPolicy,
            retryPolicy: configuration.retryPolicy
        )
        stateVersion += 1
    }

    /// Restores in-flight intent against the tasks the session still knows about.
    ///
    /// Implemented: resubmission of queued/active/waiting records whose task is gone, timers
    /// for stored retry dates, and completion of interrupted removals. Not implemented yet:
    /// finalisation journal recovery and the staging inventory; captured records are left as
    /// they are and no unknown file or task is deleted.
    private func reconcile() async throws {
        guard let session else { return }
        if let pathSource = dependencies.pathSource, let status = await pathSource.currentStatus() {
            await apply(event: .pathChanged(status))
        }
        let liveTasks = Set(await session.activeTasks())
        let records = machine?.records.values.sorted { $0.id < $1.id } ?? []
        for record in records {
            switch record.phase {
            case .waiting(.retryScheduled(let dueAt)):
                scheduleRetryTimer(record.id, generation: record.generation, at: dueAt)
            case .removing:
                pendingRemovals[record.id] = PendingRemoval(generation: record.generation, paths: record.ownedPaths)
                await completeRemovalIfUnleased(record.id)
            default:
                guard record.phase.isAwaitingTransfer, record.journal != .captured else { continue }
                let bound = record.binding.map { binding in
                    liveTasks.contains(TransferTaskReference(itemID: record.id, generation: binding.generation, taskIdentifier: binding.taskIdentifier))
                } ?? false
                if !bound {
                    await apply(event: .orphanedIntent(record.id))
                }
            }
        }
    }

    private func startConsumers() {
        guard let session else { return }
        let events = session.events
        consumers.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(.transfer(event))
            }
        })
        if let pathSource = dependencies.pathSource {
            let updates = pathSource.updates
            consumers.append(Task { [weak self] in
                for await status in updates {
                    guard let self else { return }
                    await self.ingest(.pathChanged(status))
                }
            })
        }
    }

    func detach() async {
        _ = try? await serialized { [self] in await self.runDetach() }
    }

    private func runDetach() async {
        guard lifecycle == .running else { return }
        lifecycle = .detached
        await teardown()
    }

    private func teardown() async {
        for consumer in consumers { consumer.cancel() }
        consumers = []
        for timer in retryTimers.values { timer.cancel() }
        retryTimers = [:]
        flushTask?.cancel()
        flushTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
        if let claimToken { await OwnerRegistry.shared.release(claimToken) }
        claimToken = nil
    }

    // MARK: Commands

    func run(_ command: Command) async throws {
        try await serialized { [self] in try await self.runCommand(command) }
    }

    func enqueue(_ request: DownloadRequest) async throws -> DownloadSnapshot {
        try await serialized { [self] in
            try await self.runCommand(.enqueue(request))
            guard let snapshot = await self.snapshot(for: request.id) else { throw DownloadError.unknownItem(request.id) }
            return snapshot
        }
    }

    func remove(_ ids: [DownloadID]) async throws {
        try await serialized { [self] in
            for id in ids {
                try await self.runCommand(.remove(id))
            }
        }
    }

    private func runCommand(_ command: Command) async throws {
        try requireRunning()
        if case .retry(let id) = command { await refreshSourceIfNeeded(id) }
        try await apply(command: command)
    }

    private func refreshSourceIfNeeded(_ id: DownloadID) async {
        guard let urlRefresher, let record = machine?.records[id],
              case .failed(let failure) = record.phase, failure.kind == .unauthorized else { return }
        guard let url = try? await urlRefresher.refreshedURL(for: id, metadata: record.metadata) else { return }
        try? await apply(command: .updateSource(url, id))
    }

    // MARK: Events

    func ingest(_ event: Event) async {
        _ = try? await serialized { [self] in await self.apply(event: event) }
    }

    /// Fires every scheduled retry whose time has come.
    func fireDueRetries() async {
        _ = try? await serialized { [self] in await self.runDueRetries() }
    }

    private func runDueRetries() async {
        guard let machine else { return }
        let now = await dependencies.clock.now()
        for record in machine.records.values.sorted(by: { $0.id < $1.id }) {
            guard case .waiting(.retryScheduled(let dueAt)) = record.phase, dueAt <= now else { continue }
            retryTimers.removeValue(forKey: record.id)?.cancel()
            await apply(event: .retryDue(record.id, generation: record.generation))
        }
    }

    private func retryTimerFired(_ id: DownloadID, generation: UInt64) async {
        retryTimers[id] = nil
        await ingest(.retryDue(id, generation: generation))
    }

    // MARK: Applying

    private func apply(command: Command) async throws {
        let now = await dependencies.clock.now()
        guard var next = machine else { throw DownloadError.notStarted }
        let outcome = try next.handle(command, now: now)
        try await commit(next, outcome)
        await perform(outcome.effects)
    }

    private func apply(event: Event) async {
        guard lifecycle == .running || lifecycle == .starting else { return }
        let now = await dependencies.clock.now()
        let jitter = await dependencies.jitter.nextFraction()
        guard var next = machine else { return }
        let outcome = next.handle(event, now: now, jitter: jitter)
        do {
            try await commit(next, outcome)
        } catch {
            // The index refused the write: keep the previous state and run no effects.
            return
        }
        await perform(outcome.effects)
    }

    private func commit(_ next: DownloadStateMachine, _ outcome: DownloadStateMachine.Outcome) async throws {
        let generationAdvanced = next.nextGeneration != machine?.nextGeneration
        if outcome.hasStateChanges || generationAdvanced {
            let changes = IndexChangeSet(
                upserts: outcome.changed.subtracting(outcome.deleted).sorted().compactMap { next.records[$0] },
                deletions: outcome.deleted.sorted(),
                nextGeneration: next.nextGeneration,
                defaultPolicy: outcome.globalsChanged ? next.defaultPolicy : nil
            )
            guard let store else { throw DownloadError.notStarted }
            do {
                try await store.apply(changes)
            } catch {
                throw DownloadError.persistenceFailed
            }
        }
        machine = next
        if outcome.hasStateChanges { stateVersion += 1 }
    }

    private func perform(_ effects: [Effect]) async {
        for effect in effects {
            switch effect {
            case .submit(let submission):
                await submit(submission)
            case .cancelTask(_, let taskIdentifier, let producingResumeData):
                await session?.cancel(taskIdentifier: taskIdentifier, producingResumeData: producingResumeData)
            case .finalize(let id, let generation, let captured):
                await finalize(id, generation: generation, captured: captured)
            case .discardFile(let path):
                await discard(path)
            case .deleteOwnedFiles(let id, let generation, let paths):
                pendingRemovals[id] = PendingRemoval(generation: generation, paths: paths)
                await completeRemovalIfUnleased(id)
            case .scheduleRetry(let id, let generation, let dueAt):
                scheduleRetryTimer(id, generation: generation, at: dueAt)
            case .unscheduleRetry(let id):
                retryTimers.removeValue(forKey: id)?.cancel()
            }
        }
    }

    private func submit(_ submission: TransferSubmission) async {
        guard let session else { return }
        do {
            let taskIdentifier = try await session.submit(submission)
            await apply(event: .taskBound(submission.itemID, generation: submission.generation, taskIdentifier: taskIdentifier))
        } catch {
            let failure = (error as? TransferFailure) ?? .unknown
            await apply(event: .submissionFailed(submission.itemID, generation: submission.generation, failure))
        }
    }

    private func finalize(_ id: DownloadID, generation: UInt64, captured: RelativePath) async {
        guard let layout, let record = machine?.records[id] else { return }
        let request = FinalizationRequest(
            id: id,
            generation: generation,
            stagingPath: captured,
            storageRoot: layout.root,
            expectedLength: record.request.expectedLength,
            checksum: record.request.checksum
        )
        switch await finalizer.finalize(request) {
        case .finalized(let finalPath, let integrity):
            await apply(event: .finalized(id, generation: generation, finalPath: finalPath, integrity: integrity))
        case .failed(let failure):
            await apply(event: .finalizationFailed(id, generation: generation, failure))
        case .deferred:
            break
        }
    }

    private func discard(_ path: RelativePath) async {
        guard let layout else { return }
        try? await dependencies.fileSystem.removeItem(at: layout.url(for: path))
    }

    private func completeRemovalIfUnleased(_ id: DownloadID) async {
        guard leases[id, default: []].isEmpty, let pending = pendingRemovals[id], let layout else { return }
        for path in pending.paths {
            do {
                try await dependencies.fileSystem.removeItem(at: layout.url(for: path))
            } catch {
                // Keep the tombstone; deletion is retried on the next start.
                return
            }
        }
        pendingRemovals[id] = nil
        await apply(event: .removalFinished(id, generation: pending.generation))
    }

    private func scheduleRetryTimer(_ id: DownloadID, generation: UInt64, at dueAt: Date) {
        retryTimers[id]?.cancel()
        let clock = dependencies.clock
        retryTimers[id] = Task { [weak self] in
            do {
                try await clock.sleep(until: dueAt)
            } catch {
                return
            }
            await self?.retryTimerFired(id, generation: generation)
        }
    }

    // MARK: Local files

    func localFile(for id: DownloadID) async throws -> LocalFileResult {
        try await serialized { [self] in try await self.runLocalFile(id) }
    }

    private func runLocalFile(_ id: DownloadID) async throws -> LocalFileResult {
        try requireRunning()
        guard let layout, let record = machine?.records[id] else { return .unavailable(.notDownloaded) }
        switch record.phase {
        case .completed:
            guard let finalPath = record.finalPath else { return .unavailable(.missing) }
            let url = layout.url(for: finalPath)
            guard let size = await dependencies.fileSystem.fileSize(at: url) else {
                await apply(event: .fileMissing(id, generation: record.generation))
                return .unavailable(.missing)
            }
            let expected = record.integrity?.verifiedLength ?? record.bytesWritten
            guard size == expected else {
                await apply(event: .fileCorrupt(id, generation: record.generation))
                return .unavailable(.corrupt)
            }
            let token = UUID()
            leases[id, default: []].insert(token)
            return .available(LocalFileLease(id: id, url: url, token: token))
        case .removing:
            return .unavailable(.removing)
        case .missing:
            return .unavailable(.missing)
        case .failed(let failure):
            return .unavailable(.failed(failure))
        case .queued, .active, .paused, .waiting:
            return .unavailable(.inProgress)
        }
    }

    func endAccess(_ lease: LocalFileLease) async {
        _ = try? await serialized { [self] in await self.runEndAccess(lease) }
    }

    private func runEndAccess(_ lease: LocalFileLease) async {
        leases[lease.id]?.remove(lease.token)
        if leases[lease.id]?.isEmpty == true { leases[lease.id] = nil }
        await completeRemovalIfUnleased(lease.id)
    }

    // MARK: Queries

    func snapshot(for id: DownloadID) -> DownloadSnapshot? {
        machine?.snapshot(for: id)
    }

    func allSnapshots() -> [DownloadSnapshot] {
        machine?.snapshots() ?? []
    }

    func defaultPolicy() -> NetworkPolicy {
        machine?.defaultPolicy ?? configuration.defaultPolicy
    }

    var activeLeaseCount: Int { leases.values.reduce(0) { $0 + $1.count } }
    var subscriberCount: Int { subscribers.count }

    // MARK: Snapshot stream

    func subscribe() -> AsyncStream<[DownloadSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [DownloadSnapshot].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(machine?.snapshots() ?? [])
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publishIfChanged() async {
        guard stateVersion != emittedVersion else { return }
        guard !subscribers.isEmpty else {
            emittedVersion = stateVersion
            return
        }
        let interval = configuration.snapshotInterval
        let now = await dependencies.clock.now()
        if interval > 0, let lastEmission, now < lastEmission.addingTimeInterval(interval) {
            scheduleFlush(at: lastEmission.addingTimeInterval(interval))
            return
        }
        broadcast(at: now)
    }

    private func broadcast(at now: Date) {
        let snapshots = machine?.snapshots() ?? []
        for continuation in subscribers.values { continuation.yield(snapshots) }
        emittedVersion = stateVersion
        lastEmission = now
    }

    private func scheduleFlush(at deadline: Date) {
        guard flushTask == nil else { return }
        let clock = dependencies.clock
        flushTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.flushFired()
        }
    }

    private func flushFired() async {
        flushTask = nil
        guard lifecycle == .running, stateVersion != emittedVersion else { return }
        broadcast(at: await dependencies.clock.now())
    }
}
