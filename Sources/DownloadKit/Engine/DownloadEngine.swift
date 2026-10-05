//
//  DownloadEngine.swift
//  DownloadKit
//
//  The single source of truth for in-memory state. Every command and every event runs as one
//  step of a FIFO chain, so steps never interleave even though they suspend for persistence
//  and transport calls. Within a step the state machine decides, the index persists, and only
//  then does the in-memory state change and do effects run.
//
//  Durability of events: session events go through an ordered inbox and are acknowledged to
//  the session only once applied. A terminal event or internal follow-up whose index write is
//  rejected is kept and retried at the start of every later step (and by flushPendingWork);
//  only advisory progress and waiting events may be dropped.
//
//  Reception: session events are appended to the inbox as they arrive, outside the chain;
//  only their application is a step. The reconciliation deadline is enforced outside the
//  chain, and the host's wake handlers have their own deadlines in their coordinator, so a
//  step that waits on the index holds neither.
//
//  File workers: a finaliser runs outside the chain and is an ownership claim on its item's
//  files and on the storage root. Its destination is persisted with the capture before it
//  starts. A running worker keeps its engine (and so the storage claim) alive even when the
//  manager and every lease are gone. Removal deletes the item's files, and detach releases
//  the root, only after the worker returned. Neither waits for the worker inside a step (the
//  worker's result is itself applied as a step): the worker releases its claim first, outside
//  the chain, and the waiting work resumes at the next step or, for detach, after the detach
//  step returned.
//

import Foundation

/// Identifies the facade that owns an engine; the engine holds it weakly.
final class EngineHost: Sendable {
    init() {}
}

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

    /// The start-up reconciliation fence.
    private enum Fence: Equatable {
        case notStarted
        case open(deadline: Date)
        case resolved
        case unresolved(ReconciliationUnresolvedReason)
    }

    private struct PendingRemoval {
        let generation: UInt64
        let paths: [RelativePath]
    }

    private struct AttemptKey: Hashable, Comparable {
        let id: DownloadID
        let generation: UInt64

        static func < (lhs: AttemptKey, rhs: AttemptKey) -> Bool {
            (lhs.id, lhs.generation) < (rhs.id, rhs.generation)
        }
    }

    let configuration: DownloadConfiguration
    private let urlRefresher: (any URLRefreshing)?
    private let finalizer: any DownloadFinalizing
    private let backgroundEvents: BackgroundEventsCoordinator?
    /// The facade that created this engine. When it is gone while a lease keeps the engine
    /// alive, ending the last lease detaches the engine and frees the storage root.
    private weak var host: EngineHost?

    private var lifecycle: Lifecycle = .idle
    private var machine: DownloadStateMachine?
    private var store: (any DownloadIndexStore)?
    private var session: (any TransferSession)?
    private var layout: StorageLayout?
    private var claimToken: UUID?

    private var tail: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[DownloadSnapshot]>.Continuation] = [:]
    /// Outstanding leases per item, each with the file it protects.
    private var leases: [DownloadID: [UUID: RelativePath]] = [:]
    /// Queued deletions held back because a lease still protects the file. Their persisted
    /// intent stays; each is retried when the last lease on its path ends.
    private var leaseHeldCleanup: Set<RelativePath> = []
    private var pendingRemovals: [DownloadID: PendingRemoval] = [:]
    /// Removals that could not finish yet (a failed deletion or write, or a running finaliser).
    private var unfinishedRemovals: Set<DownloadID> = []
    /// Queued deletions that failed; their persisted intent is retried.
    private var failedCleanup: Set<RelativePath> = []
    private var retryTimers: [DownloadID: Task<Void, Never>] = [:]
    /// Running finalisers. An entry is removed as soon as the finaliser returned, before its
    /// result is applied: from then on it can no longer create files.
    private var finalizations: [AttemptKey: Task<Void, Never>] = [:]
    /// Finaliser results not yet applied.
    private var finalizationResultsPending = 0
    /// Captured records found at start, finalised once the startup replay was drained.
    private var recoveredFinalizations: [AttemptKey: RelativePath] = [:]
    /// Callers of ``detach()`` waiting for running finalisers to return.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var fence: Fence = .notStarted
    private var fenceTimer: Task<Void, Never>?
    private var consumers: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var lastEmission: Date?
    private var stateVersion: UInt64 = 0
    private var emittedVersion: UInt64 = 0

    /// Session events not yet applied, oldest first.
    private var inbox: [TransferSessionEvent] = []
    /// A drain step is queued and has not started yet.
    private var drainQueued = false
    /// The inbox head could not be committed at the last drain. Entries merely received and
    /// not yet drained do not count.
    private var inboxBlocked = false
    /// Critical internal or directly ingested events whose index write was rejected.
    private var retained: [Event] = []
    /// Awaiting-transfer records without a live task at start. Decided only after the session
    /// delivered its backlog.
    private var orphanCandidates: [DownloadID: UInt64] = [:]

    private var dependencies: DownloadDependencies { configuration.dependencies }

    init(
        configuration: DownloadConfiguration,
        urlRefresher: (any URLRefreshing)?,
        finalizer: any DownloadFinalizing,
        backgroundEvents: BackgroundEventsCoordinator? = nil,
        host: EngineHost? = nil
    ) {
        self.configuration = configuration
        self.urlRefresher = urlRefresher
        self.finalizer = finalizer
        self.backgroundEvents = backgroundEvents
        self.host = host
    }

    // MARK: Serialisation

    /// Runs `operation` after every previously submitted step has finished. Retained work is
    /// retried first.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await submitStep(operation).value
    }

    /// Appends `operation` to the chain without waiting for it.
    @discardableResult
    private func submitStep<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, any Error> {
        let previous = tail
        let step = Task<T, any Error> { [self] in
            await previous?.value
            await self.runPendingWorkIfNeeded()
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
        return step
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
            await reconcile()
            startConsumers()
            await connectRestarts()
        } catch {
            teardown()
            await releaseClaimIfHeld()
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
    /// Order:
    /// 1. Map every system task through its description, in this session
    ///    (``SystemTransferTask/reference(inSession:)``). Unmapped tasks, and tasks whose
    ///    description names another session, are foreign and left alone. A
    ///    task matching an awaiting record's generation is adopted (its binding is written if
    ///    it was lost) instead of being replaced. Any other package task, including one a
    ///    paused, cancelled or removed record asked to stop, is cancelled again.
    /// 2. A stopping binding is enforced only against the exact task it names: same session,
    ///    and a live task whose description maps to the same item and stopping generation.
    ///    When that task is absent (its number is free, unmapped or names another attempt)
    ///    the stop is acknowledged and the other task is left alone.
    /// 3. The current path is applied. For attempts not yet confirmed it only changes the
    ///    explanation; it never creates a replacement attempt.
    /// 4. Queued deletions are retried, retry timers re-armed, removals resumed and completed
    ///    files inspected (only a verified absence makes an item missing). Captured records
    ///    are finalised again only after the startup replay was drained (step 5), so a replayed
    ///    completion is applied before a recovered result can change the capture.
    /// 5. Awaiting records with no live task become orphan candidates, and so do records
    ///    restored as stopped while unconfirmed (``IndexRecord/stoppedWhileUnconfirmed``): a
    ///    restart asked for before or after the relaunch stays deferred until the backlog proves
    ///    the old attempt gone, so a buffered completion is captured, never discarded. The fence stays open
    ///    until the session reports its backlog delivered (or a wake's events finished), so a
    ///    completion buffered before start is applied first; only then are candidates
    ///    resubmitted. A candidate paused or cancelled meanwhile stays a candidate: a stop does
    ///    not prove that its task ended. At ``DownloadConfiguration/reconciliationTimeout`` the
    ///    fence becomes unresolved: nothing is concluded and no replacement is created.
    private func reconcile() async {
        guard let session else { return }
        let tasks = await session.systemTasks().sorted { $0.taskIdentifier < $1.taskIdentifier }
        var live: [Int: TransferTaskReference] = [:]
        for task in tasks {
            if let reference = task.reference(inSession: session.identifier) { live[task.taskIdentifier] = reference }
        }
        var adopted: Set<AttemptKey> = []
        var stopped: Set<Int> = []
        for task in tasks {
            guard let reference = task.reference(inSession: session.identifier) else { continue }
            guard let record = machine?.records[reference.itemID] else {
                await stopTask(reference.taskIdentifier, of: reference.itemID, producingResumeData: false)
                stopped.insert(reference.taskIdentifier)
                continue
            }
            let key = AttemptKey(id: reference.itemID, generation: reference.generation)
            // A restored stop that was never confirmed is resolved by the state machine: the
            // task is adopted by a deferred restart or the stop is enforced on exactly it.
            let stoppedUnconfirmed = record.generation == reference.generation && (machine?.isStoppedAndUnconfirmed(record) ?? false)
            let wanted = record.generation == reference.generation
                && (record.phase.isAwaitingTransfer || stoppedUnconfirmed)
                && record.journal != .captured
                && !adopted.contains(key)
            if wanted {
                adopted.insert(key)
                // Confirms the attempt; writes only when the binding was lost or differs.
                await applyRetaining(.taskBound(reference.itemID, generation: reference.generation, taskIdentifier: reference.taskIdentifier))
            } else {
                let keepsResumeData = record.generation == reference.generation && Self.isStopped(record.phase)
                await stopTask(reference.taskIdentifier, of: reference.itemID, producingResumeData: keepsResumeData)
                stopped.insert(reference.taskIdentifier)
            }
        }

        for record in sortedRecords() {
            guard let stopping = record.stoppingBinding else { continue }
            let task = live[stopping.taskIdentifier]
            let sameTask = stopping.sessionIdentifier == session.identifier
                && task?.itemID == record.id
                && task?.generation == stopping.generation
            if sameTask {
                if !stopped.contains(stopping.taskIdentifier) {
                    await stopTask(stopping.taskIdentifier, of: record.id, producingResumeData: record.phase != .removing)
                }
            } else {
                await applyRetaining(.stopAcknowledged(record.id, taskIdentifier: stopping.taskIdentifier))
            }
        }

        if let pathSource = dependencies.pathSource, let status = await pathSource.currentStatus() {
            await applyRetaining(.pathChanged(status))
        }

        for path in (machine?.cleanup ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
            await discard(path)
        }

        for record in sortedRecords() {
            switch record.phase {
            case .waiting(.retryScheduled(let dueAt)):
                scheduleRetryTimer(record.id, generation: record.generation, at: dueAt)
            case .removing:
                pendingRemovals[record.id] = PendingRemoval(generation: record.generation, paths: record.ownedPaths)
                await completeRemovalIfUnleased(record.id)
            case .completed:
                await inspectCompletedAtStart(record)
            case .active where record.journal == .captured:
                if let captured = record.stagingPath {
                    recoveredFinalizations[AttemptKey(id: record.id, generation: record.generation)] = captured
                }
            default:
                let stoppedUnconfirmed = machine?.isStoppedAndUnconfirmed(record) ?? false
                guard record.phase.isAwaitingTransfer || stoppedUnconfirmed, record.journal != .captured else { continue }
                if !adopted.contains(AttemptKey(id: record.id, generation: record.generation)) {
                    orphanCandidates[record.id] = record.generation
                }
            }
        }

        if orphanCandidates.isEmpty && recoveredFinalizations.isEmpty {
            fence = .resolved
        } else {
            await openFence()
        }
    }

    private func openFence() async {
        let clock = dependencies.clock
        let deadline = await clock.now().addingTimeInterval(configuration.reconciliationTimeout)
        fence = .open(deadline: deadline)
        fenceTimer = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.fenceDeadlinePassed()
        }
    }

    /// The backlog marker did not come in time. The status becomes unresolved at once,
    /// outside the chain, so a step waiting on the index cannot hold it past the deadline. This
    /// concludes nothing and changes no record; the follow-up runs as a step.
    private func fenceDeadlinePassed() async {
        fenceTimer = nil
        guard lifecycle == .running, case .open = fence else { return }
        fence = .unresolved(.deadlineExceeded)
        submitStep { [self] in await self.runFenceDeadline() }
    }

    /// Tasks that can be found now are adopted; for the rest nothing is concluded. Recovered
    /// finalisations start: a late replay of their completion can no longer capture again
    /// (one capture per attempt).
    private func runFenceDeadline() async {
        guard lifecycle == .running else { return }
        if fence == .unresolved(.deadlineExceeded) {
            await adoptLiveCandidates()
            if orphanCandidates.isEmpty { markFence(.resolved) }
        }
        await startRecoveredFinalizations()
    }

    /// The session's stream finished. An open fence cannot be closed by a marker any more.
    private func sessionEventsEnded() async {
        _ = try? await serialized { [self] in
            guard await self.isFenceOpen() else { return }
            await self.markFence(.unresolved(.sessionEnded))
            await self.startRecoveredFinalizations()
        }
    }

    private func isFenceOpen() -> Bool {
        guard lifecycle == .running, case .open = fence else { return false }
        return true
    }

    private func markFence(_ state: Fence) {
        fence = state
        if case .open = state { return }
        fenceTimer?.cancel()
        fenceTimer = nil
    }

    /// Closes the fence after the session proved its backlog drained: resolves the orphan
    /// candidates, then starts recovered finalisations. Returns false when a write was
    /// rejected; the marker is then retried.
    private func resolveFence() async -> Bool {
        guard await resolveOrphanCandidates() else { return false }
        if fence != .resolved { markFence(.resolved) }
        await startRecoveredFinalizations()
        return true
    }

    /// Adopts orphan candidates whose task the session reports now. Presence is proof;
    /// absence is not, so nothing else changes.
    private func adoptLiveCandidates() async {
        guard !orphanCandidates.isEmpty, let session else { return }
        var live: [AttemptKey: Int] = [:]
        for task in await session.systemTasks() {
            guard let reference = task.reference(inSession: session.identifier) else { continue }
            live[AttemptKey(id: reference.itemID, generation: reference.generation)] = reference.taskIdentifier
        }
        for key in orphanCandidates.map({ AttemptKey(id: $0.key, generation: $0.value) }).sorted() {
            guard isStillCandidate(key) else {
                orphanCandidates[key.id] = nil
                continue
            }
            if let taskIdentifier = live[key] {
                orphanCandidates[key.id] = nil
                await applyRetaining(.taskBound(key.id, generation: key.generation, taskIdentifier: taskIdentifier))
            }
        }
    }

    /// Whether an orphan candidate still needs its disposition: its attempt is current, holds
    /// no capture, and either expects a transfer or was stopped while unconfirmed (a stop does
    /// not prove that its task ended).
    private func isStillCandidate(_ key: AttemptKey) -> Bool {
        guard let machine, let record = machine.records[key.id], record.generation == key.generation,
              record.journal != .captured else { return false }
        return record.phase.isAwaitingTransfer || machine.isStoppedAndUnconfirmed(record)
    }

    private func startRecoveredFinalizations() async {
        for key in recoveredFinalizations.keys.sorted() {
            // Each entry is dropped only once its finaliser is registered, so the work is never
            // invisible in between.
            defer { recoveredFinalizations[key] = nil }
            guard let captured = recoveredFinalizations[key], let record = machine?.records[key.id], record.generation == key.generation,
                  record.journal == .captured, record.phase == .active, record.stagingPath == captured else { continue }
            await startFinalization(key.id, generation: key.generation, captured: captured)
        }
    }

    func reconciliationStatus() -> ReconciliationStatus {
        switch fence {
        case .notStarted: return .notStarted
        case .open(let deadline): return .awaitingBacklog(deadline: deadline)
        case .resolved: return .resolved
        case .unresolved(let reason): return .unresolved(items: orphanCandidates.keys.sorted(), reason: reason)
        }
    }

    private static func isStopped(_ phase: RecordPhase) -> Bool {
        switch phase {
        case .paused, .failed: return true
        default: return false
        }
    }

    private func sortedRecords() -> [IndexRecord] {
        machine?.records.values.sorted { $0.id < $1.id } ?? []
    }

    private func inspectCompletedAtStart(_ record: IndexRecord) async {
        guard let layout, let finalPath = record.finalPath else { return }
        guard let status = try? await dependencies.fileSystem.inspectItem(at: layout.url(for: finalPath)) else {
            // Inspection failed: nothing is concluded at start.
            return
        }
        if status == .absent {
            await applyRetaining(.fileMissing(record.id, generation: record.generation))
        }
    }

    /// Resubmits orphan candidates once the backlog was delivered. Returns false when a write
    /// was rejected; the remaining candidates are retried with the marker.
    private func resolveOrphanCandidates() async -> Bool {
        guard !orphanCandidates.isEmpty, let session else { return true }
        var live: [AttemptKey: Int] = [:]
        for task in await session.systemTasks() {
            guard let reference = task.reference(inSession: session.identifier) else { continue }
            live[AttemptKey(id: reference.itemID, generation: reference.generation)] = reference.taskIdentifier
        }
        var complete = true
        for key in orphanCandidates.map({ AttemptKey(id: $0.key, generation: $0.value) }).sorted() {
            guard isStillCandidate(key) else {
                orphanCandidates[key.id] = nil
                continue
            }
            if let taskIdentifier = live[key] {
                orphanCandidates[key.id] = nil
                await applyRetaining(.taskBound(key.id, generation: key.generation, taskIdentifier: taskIdentifier))
                continue
            }
            if await apply(event: .orphanedIntent(key.id, generation: key.generation)) {
                orphanCandidates[key.id] = nil
            } else {
                complete = false
            }
        }
        return complete
    }

    private func startConsumers() {
        guard let session else { return }
        let events = session.events
        consumers.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.accept(event)
            }
            await self?.sessionEventsEnded()
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
        // Second phase, outside the chain: a running finaliser applies its result as a step,
        // so waiting for it inside the detach step would never end.
        await waitForFinalizers()
    }

    /// Stops observing and ends snapshot streams. The storage claim is released once no
    /// finaliser runs and no lease is outstanding: no other manager can own the root while a
    /// worker can still write to it or a leased file must stay on disk. Unapplied session
    /// events stay unacknowledged.
    private func runDetach() async {
        guard lifecycle == .running else { return }
        lifecycle = .detached
        teardown()
        await releaseClaimIfQuiet()
    }

    private func teardown() {
        for consumer in consumers { consumer.cancel() }
        consumers = []
        for timer in retryTimers.values { timer.cancel() }
        retryTimers = [:]
        // Cancellation is cooperative: the entries stay until each finaliser returned.
        for finalization in finalizations.values { finalization.cancel() }
        fenceTimer?.cancel()
        fenceTimer = nil
        flushTask?.cancel()
        flushTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    private func waitForFinalizers() async {
        guard !finalizations.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters.append(continuation)
        }
    }

    private func releaseClaimIfQuiet() async {
        guard leases.isEmpty, finalizations.isEmpty else { return }
        await releaseClaimIfHeld()
    }

    private func releaseClaimIfHeld() async {
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

    /// Retries retained events, failed removals and queued deletions, throwing
    /// ``DownloadError/persistenceFailed`` when events are still waiting for an index write,
    /// and ``DownloadError/reconciliationUnresolved`` when start-up reconciliation timed out and
    /// some attempts still cannot be found.
    func flushPendingWork() async throws {
        try await serialized { [self] in try await self.runFlush() }
    }

    private func runFlush() async throws {
        try requireRunning()
        if !retained.isEmpty || inboxBlocked { throw DownloadError.persistenceFailed }
        if case .unresolved(let reason) = fence {
            await adoptLiveCandidates()
            // A session that could not deliver its backlog is resolved only by its marker.
            guard orphanCandidates.isEmpty, reason != .sessionStorageFailed else { throw DownloadError.reconciliationUnresolved }
            markFence(.resolved)
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

    /// Applies one event as its own step. A critical event whose write is rejected is kept.
    func ingest(_ event: Event) async {
        _ = try? await serialized { [self] in await self.applyRetaining(event) }
    }

    /// Receives one session event outside the chain: it joins the ordered inbox at once, and
    /// one drain step is queued to apply it. A step suspended on the index delays application,
    /// never reception.
    private func accept(_ event: TransferSessionEvent) async {
        guard lifecycle == .running else { return }
        inbox.append(event)
        if !drainQueued {
            drainQueued = true
            submitStep { [self] in await self.runQueuedDrain() }
        }
    }

    /// Usually the step's pending-work prelude has applied the inbox already (one attempt per
    /// step); this drains only when no drain started since the step was queued.
    private func runQueuedDrain() async {
        guard drainQueued else { return }
        await drainInbox()
    }

    /// Applies inbox entries in order until one cannot be committed, then acknowledges the
    /// applied prefix to the session. A wake marker stuck behind an uncommitted entry leaves its
    /// handlers to their deadlines.
    private func drainInbox() async {
        guard lifecycle == .running else { return }
        // Events received from here on queue another drain step.
        drainQueued = false
        var applied: UInt64?
        var blocked = false
        while let head = inbox.first {
            guard await process(head) else {
                blocked = true
                break
            }
            inbox.removeFirst()
            applied = head.sequence
        }
        inboxBlocked = blocked
        if let applied, let session { await session.acknowledge(through: applied) }
    }

    private func process(_ envelope: TransferSessionEvent) async -> Bool {
        switch envelope.payload {
        case .transfer(let event):
            let committed = await apply(event: .transfer(event))
            return committed || (!event.isTerminal && lifecycle == .running)
        case .backlogDelivered:
            return await resolveFence()
        case .backlogUnavailable:
            // The session's backlog may be incomplete: nothing is concluded, the fence stays
            // closed to replacement and reports why. Found tasks are still adopted, and
            // recovered finalisations start (one capture per attempt makes that safe).
            if isFenceOpen() {
                markFence(.unresolved(.sessionStorageFailed))
                await adoptLiveCandidates()
                await startRecoveredFinalizations()
            }
            return true
        case .backgroundEventsFinished:
            // The system delivered every event of the wake: also a drain boundary. Only the
            // handlers accepted before the system reported it are answered.
            guard await resolveFence() else { return false }
            if let backgroundEvents { await backgroundEvents.eventsApplied(through: envelope.wakeOrder) }
            return true
        }
    }

    /// Connects the adapter's restart path: a refused continuation is submitted again from
    /// zero by this manager, through ``submit(_:)`` and so through the host's transfer URL hook.
    private func connectRestarts() async {
        guard let session = session as? any RestartingTransferSession else { return }
        await session.setRestartHandler { [weak self] reference in
            guard let self else { return false }
            return await self.replaceRefusedAttempt(reference)
        }
    }

    /// Submits the attempt of a refused continuation again from zero, as a step. Returns
    /// `false` while this manager is not running (the adapter keeps the restart for the next
    /// one), `true` once decided: replaced, or nothing to replace because the attempt is no
    /// longer current, no longer awaits a transfer, holds a capture or waits for reconciliation
    /// (which then adopts a live task or resubmits under a new generation).
    func replaceRefusedAttempt(_ reference: TransferTaskReference) async -> Bool {
        guard lifecycle == .running else { return false }
        let handled = try? await serialized { [self] in await self.runReplacement(reference) }
        return handled ?? false
    }

    private func runReplacement(_ reference: TransferTaskReference) async -> Bool {
        guard lifecycle == .running else { return false }
        guard orphanCandidates[reference.itemID] == nil,
              let submission = machine?.replacementSubmission(for: reference.itemID, generation: reference.generation, refusedTask: reference.taskIdentifier) else { return true }
        await submit(submission)
        return true
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
            await applyRetaining(.retryDue(record.id, generation: record.generation))
        }
    }

    private func retryTimerFired(_ id: DownloadID, generation: UInt64) async {
        retryTimers[id] = nil
        await ingest(.retryDue(id, generation: generation))
    }

    // MARK: Pending work

    private var hasPendingWork: Bool {
        !retained.isEmpty || !inbox.isEmpty || !unfinishedRemovals.isEmpty || !failedCleanup.isEmpty
    }

    /// Bounded in-process recovery: one attempt per step, never a loop.
    private func runPendingWorkIfNeeded() async {
        guard lifecycle == .running, hasPendingWork else { return }
        if !retained.isEmpty {
            let batch = retained
            retained = []
            for event in batch { await applyRetaining(event) }
        }
        for id in unfinishedRemovals.sorted() {
            await completeRemovalIfUnleased(id)
        }
        for path in failedCleanup.sorted(by: { $0.rawValue < $1.rawValue }) {
            await discard(path)
        }
        if !inbox.isEmpty { await drainInbox() }
    }

    var pendingWorkCount: Int { retained.count + inbox.count + unfinishedRemovals.count + failedCleanup.count }

    // MARK: Applying

    private func apply(command: Command) async throws {
        let now = await dependencies.clock.now()
        guard var next = machine else { throw DownloadError.notStarted }
        let outcome = try next.handle(command, now: now)
        try await commit(next, outcome)
        await perform(outcome.effects)
    }

    /// Applies `event`; returns false when the index rejected the write (state unchanged, no
    /// effects) or the engine is not running.
    @discardableResult
    private func apply(event: Event) async -> Bool {
        guard lifecycle == .running || lifecycle == .starting else { return false }
        let now = await dependencies.clock.now()
        let jitter = await dependencies.jitter.nextFraction()
        guard var next = machine else { return false }
        let outcome = next.handle(event, now: now, jitter: jitter)
        do {
            try await commit(next, outcome)
        } catch {
            return false
        }
        await perform(outcome.effects)
        return true
    }

    /// Applies `event` and keeps it for a later attempt when it is critical and its write was
    /// rejected.
    private func applyRetaining(_ event: Event) async {
        guard !(await apply(event: event)) else { return }
        guard lifecycle == .running || lifecycle == .starting, Self.isCritical(event) else { return }
        retained.append(event)
    }

    private static func isCritical(_ event: Event) -> Bool {
        switch event {
        case .transfer(let transfer): return transfer.isTerminal
        case .pathChanged: return false
        default: return true
        }
    }

    private func commit(_ next: DownloadStateMachine, _ outcome: DownloadStateMachine.Outcome) async throws {
        let generationAdvanced = next.nextGeneration != machine?.nextGeneration
        if outcome.hasStateChanges || generationAdvanced {
            let changes = IndexChangeSet(
                upserts: outcome.changed.subtracting(outcome.deleted).sorted().compactMap { next.records[$0] },
                deletions: outcome.deleted.sorted(),
                nextGeneration: next.nextGeneration,
                defaultPolicy: outcome.globalsChanged ? next.defaultPolicy : nil,
                cleanupQueued: outcome.cleanupQueued.sorted { $0.rawValue < $1.rawValue },
                cleanupCompleted: outcome.cleanupCompleted.sorted { $0.rawValue < $1.rawValue }
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
            case .cancelTask(let id, let taskIdentifier, let producingResumeData):
                await stopTask(taskIdentifier, of: id, producingResumeData: producingResumeData)
            case .finalize(let id, let generation, let captured):
                await startFinalization(id, generation: generation, captured: captured)
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

    /// Cancels a task, then records the acknowledgement that ends a pending stop.
    private func stopTask(_ taskIdentifier: Int, of id: DownloadID, producingResumeData: Bool) async {
        guard let session else { return }
        await session.cancel(taskIdentifier: taskIdentifier, producingResumeData: producingResumeData)
        await applyRetaining(.stopAcknowledged(id, taskIdentifier: taskIdentifier))
    }

    private func submit(_ submission: TransferSubmission) async {
        guard let session else { return }
        var submission = submission
        if let urlRefresher, let record = machine?.records[submission.itemID] {
            do {
                let url = try await urlRefresher.transferURL(for: submission.itemID, sourceURL: submission.url, metadata: record.metadata)
                submission = submission.with(url: url)
            } catch {
                await applyRetaining(.submissionFailed(submission.itemID, generation: submission.generation, .credentialsUnavailable))
                return
            }
            // The resolver suspended: only submit if the attempt is still the current one.
            guard let current = machine?.records[submission.itemID], current.generation == submission.generation,
                  current.phase.isAwaitingTransfer else { return }
        }
        do {
            let taskIdentifier = try await session.submit(submission)
            await applyRetaining(.taskBound(submission.itemID, generation: submission.generation, taskIdentifier: taskIdentifier))
        } catch {
            let failure = (error as? TransferFailure) ?? .unknown
            await applyRetaining(.submissionFailed(submission.itemID, generation: submission.generation, failure))
        }
    }

    /// Runs the finaliser outside the command chain. Its result is applied as an ordinary,
    /// generation-checked event; one finalisation per attempt at a time. The destination was
    /// persisted with the capture, so a file the finaliser creates is always owned.
    private func startFinalization(_ id: DownloadID, generation: UInt64, captured: RelativePath) async {
        let now = await dependencies.clock.now()
        let key = AttemptKey(id: id, generation: generation)
        guard finalizations[key] == nil, lifecycle == .running || lifecycle == .starting,
              let layout, let record = machine?.records[id], record.generation == generation,
              record.journal == .captured else { return }
        let request = FinalizationRequest(
            id: id,
            generation: generation,
            stagingPath: captured,
            destination: record.finalizationDestination ?? .media(generation: generation),
            storageRoot: layout.root,
            capturedBytes: record.bytesWritten,
            validators: record.validators,
            expectedLength: record.request.expectedLength,
            checksum: record.request.checksum,
            deadline: now.addingTimeInterval(configuration.finalizationBudget)
        )
        let finalizer = self.finalizer
        let claim = WorkerClaim(self)
        finalizations[key] = Task {
            let result = await finalizer.finalize(request)
            // The worker holds its engine, and with it the storage claim, until here.
            await claim.release()?.finalizationEnded(id, generation: generation, result: result)
        }
    }

    /// The finaliser returned and can no longer create files. Its claim ends here, outside
    /// the chain; its result is then applied as a step, which also lets a removal waiting for
    /// it finish. The step holds the engine only like any other step: once the worker's
    /// retention is gone, a released manager's engine without leases can end.
    private func finalizationEnded(_ id: DownloadID, generation: UInt64, result: FinalizationResult) async {
        finalizations[AttemptKey(id: id, generation: generation)] = nil
        finalizationResultsPending += 1
        if finalizations.isEmpty {
            let waiters = drainWaiters
            drainWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        if lifecycle == .detached { await releaseClaimIfQuiet() }
        submitStep { [self] in
            await self.applyFinalizationResult(id, generation: generation, result: result)
            await self.finalizationResultApplied()
        }
    }

    private func finalizationResultApplied() {
        finalizationResultsPending -= 1
    }

    private func applyFinalizationResult(_ id: DownloadID, generation: UInt64, result: FinalizationResult) async {
        switch result {
        case .finalized(let finalPath, let integrity):
            await applyRetaining(.finalized(id, generation: generation, finalPath: finalPath, integrity: integrity))
        case .failed(let failure):
            await applyRetaining(.finalizationFailed(id, generation: generation, failure))
        case .deferred:
            break
        }
    }

    /// Finalisers running, waiting to start after the startup replay, or whose result is not
    /// applied yet.
    var finalizationsInFlight: Int { finalizations.count + recoveredFinalizations.count + finalizationResultsPending }

    /// Deletes a file whose deletion intent is persisted, and closes the intent only after the
    /// deletion was verified. A file some record owns again is kept (ownership wins). A file an
    /// outstanding lease protects is kept until that lease ends. A failed
    /// deletion, inspection or write keeps the intent and is retried at the next step.
    private func discard(_ path: RelativePath) async {
        guard let layout, let machine, machine.cleanup.contains(path) else { return }
        if isLeased(path) {
            // A lease promises its URL until it ends: the intent stays and the deletion runs
            // when the last lease on this path ends (or at the next owner's start).
            leaseHeldCleanup.insert(path)
            failedCleanup.remove(path)
            return
        }
        if !machine.isOwned(path) {
            let url = layout.url(for: path)
            do {
                try await dependencies.fileSystem.removeItem(at: url)
                guard try await dependencies.fileSystem.inspectItem(at: url) == .absent else {
                    failedCleanup.insert(path)
                    return
                }
            } catch {
                failedCleanup.insert(path)
                return
            }
        }
        if await apply(event: .cleanupFinished(path)) {
            failedCleanup.remove(path)
        } else {
            failedCleanup.insert(path)
        }
    }

    private func isLeased(_ path: RelativePath) -> Bool {
        leases.values.contains { $0.values.contains(path) }
    }

    /// Deletes a tombstoned item's files once no lease protects them and no finaliser of the
    /// item can still create one. The pending removal is kept until the record's deletion is
    /// committed; a failed file deletion or index write is retried at the next step.
    private func completeRemovalIfUnleased(_ id: DownloadID) async {
        guard lifecycle == .running, leases[id, default: [:]].isEmpty, let pending = pendingRemovals[id], let layout else { return }
        guard !finalizations.keys.contains(where: { $0.id == id }) else {
            // Retried at the step that applies the finaliser's result.
            unfinishedRemovals.insert(id)
            return
        }
        for path in pending.paths {
            do {
                try await dependencies.fileSystem.removeItem(at: layout.url(for: path))
            } catch {
                unfinishedRemovals.insert(id)
                return
            }
        }
        if await apply(event: .removalFinished(id, generation: pending.generation)) {
            pendingRemovals[id] = nil
            unfinishedRemovals.remove(id)
        } else {
            unfinishedRemovals.insert(id)
        }
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
            let status: FileStatus
            do {
                status = try await dependencies.fileSystem.inspectItem(at: url)
            } catch {
                // Unknown is not absent: keep the record and its path.
                throw DownloadError.fileAccessFailed(id)
            }
            switch status {
            case .absent:
                await applyRetaining(.fileMissing(id, generation: record.generation))
                return .unavailable(.missing)
            case .file(let size):
                let expected = record.integrity?.verifiedLength ?? record.bytesWritten
                guard size == expected else {
                    await applyRetaining(.fileCorrupt(id, generation: record.generation))
                    return .unavailable(.corrupt)
                }
            }
            let token = UUID()
            leases[id, default: [:]][token] = finalPath
            return .available(LocalFileLease(id: id, url: url, token: token, owner: self))
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

    /// Ends a lease this engine issued. Ending a lease twice does nothing.
    func endAccess(_ lease: LocalFileLease) async {
        _ = try? await serialized { [self] in await self.runEndAccess(lease) }
    }

    private func runEndAccess(_ lease: LocalFileLease) async {
        guard let released = leases[lease.id]?.removeValue(forKey: lease.token) else { return }
        if leases[lease.id]?.isEmpty == true { leases[lease.id] = nil }
        if lifecycle == .running, host == nil {
            // The manager was released while this lease kept its engine alive: stop owning
            // the root now instead of waiting for the lease value to be released.
            await runDetach()
            return
        }
        switch lifecycle {
        case .running:
            if leaseHeldCleanup.contains(released), !isLeased(released) {
                leaseHeldCleanup.remove(released)
                await discard(released)
            }
            await completeRemovalIfUnleased(lease.id)
        case .detached:
            // A detached owner never deletes: the next owner finishes removals on its start.
            await releaseClaimIfQuiet()
        case .idle, .starting:
            break
        }
    }

    // MARK: Inventory

    /// Files in `staging/` and `media/` that no record owns and no queued deletion names.
    /// They are reported, never deleted: an unknown file is kept until the host decides.
    func unreferencedFiles() async throws -> [RelativePath] {
        try await serialized { [self] in try await self.runInventory() }
    }

    private func runInventory() async throws -> [RelativePath] {
        try requireRunning()
        guard let layout, let machine else { return [] }
        var known = Set(machine.records.values.flatMap(\.ownedPaths))
        known.formUnion(machine.cleanup)
        var unknown: [RelativePath] = []
        for (directory, name) in [(layout.staging, StorageLayout.stagingDirectory), (layout.media, StorageLayout.mediaDirectory)] {
            let entries: [String]
            do {
                entries = try await dependencies.fileSystem.contentsOfDirectory(at: directory)
            } catch {
                throw DownloadError.storageUnavailable
            }
            for entry in entries {
                guard let path = try? RelativePath("\(name)/\(entry)"), !known.contains(path) else { continue }
                unknown.append(path)
            }
        }
        return unknown.sorted { $0.rawValue < $1.rawValue }
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

    var isDetached: Bool { lifecycle == .detached }
    var activeLeaseCount: Int { leases.values.reduce(0) { $0 + $1.count } }
    var subscriberCount: Int { subscribers.count }

    // MARK: Snapshot stream

    func subscribe() -> (UUID, AsyncStream<[DownloadSnapshot]>) {
        let (stream, continuation) = AsyncStream.makeStream(of: [DownloadSnapshot].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        guard lifecycle != .detached else {
            continuation.finish()
            return (id, stream)
        }
        subscribers[id] = continuation
        continuation.yield(machine?.snapshots() ?? [])
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
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

/// A running file worker's strong hold on its engine. The engine's storage claim is weak in
/// the registry, so this hold is what keeps another manager from claiming the root while the
/// worker can still create files. It is given up exactly once, when the worker returned.
private actor WorkerClaim {
    private var engine: DownloadEngine?

    init(_ engine: DownloadEngine) {
        self.engine = engine
    }

    /// Hands the engine over for deregistration and drops the hold.
    func release() -> DownloadEngine? {
        defer { engine = nil }
        return engine
    }
}
