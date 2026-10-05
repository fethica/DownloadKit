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
    private var failedRemovals: Set<DownloadID> = []
    private var retryTimers: [DownloadID: Task<Void, Never>] = [:]
    private var finalizations: [AttemptKey: Task<Void, Never>] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var lastEmission: Date?
    private var stateVersion: UInt64 = 0
    private var emittedVersion: UInt64 = 0

    /// Session events not yet applied, oldest first.
    private var inbox: [TransferSessionEvent] = []
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
        backgroundEvents: BackgroundEventsCoordinator? = nil
    ) {
        self.configuration = configuration
        self.urlRefresher = urlRefresher
        self.finalizer = finalizer
        self.backgroundEvents = backgroundEvents
    }

    // MARK: Serialisation

    /// Runs `operation` after every previously submitted step has finished. Retained work is
    /// retried first.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
            await reconcile()
            startConsumers()
        } catch {
            await teardown(releaseClaim: true)
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
    /// 1. Map every system task through its description. Unmapped tasks are left alone. A
    ///    task matching an awaiting record's generation is adopted (its binding is written if
    ///    it was lost) instead of being replaced. Any other package task, including one a
    ///    paused, cancelled or removed record asked to stop, is cancelled again.
    /// 2. Stopping bindings whose task is gone are acknowledged.
    /// 3. Retry timers are re-armed, removals resume, captured records are finalised again
    ///    and completed files are inspected (only a verified absence makes an item missing).
    /// 4. Awaiting records with no live task become orphan candidates. They are resubmitted
    ///    only when the session reports that its backlog was delivered, so a completion that
    ///    was buffered before start is applied first.
    private func reconcile() async {
        guard let session else { return }
        if let pathSource = dependencies.pathSource, let status = await pathSource.currentStatus() {
            await applyRetaining(.pathChanged(status))
        }

        let tasks = await session.systemTasks().sorted { $0.taskIdentifier < $1.taskIdentifier }
        var adopted: Set<AttemptKey> = []
        var stopped: Set<Int> = []
        for task in tasks {
            guard let reference = task.reference else { continue }
            guard let record = machine?.records[reference.itemID] else {
                await stopTask(reference.taskIdentifier, of: reference.itemID, producingResumeData: false)
                stopped.insert(reference.taskIdentifier)
                continue
            }
            let key = AttemptKey(id: reference.itemID, generation: reference.generation)
            let wanted = record.generation == reference.generation
                && record.phase.isAwaitingTransfer
                && record.journal != .captured
                && !adopted.contains(key)
            if wanted {
                adopted.insert(key)
                if record.binding?.taskIdentifier != reference.taskIdentifier || record.binding?.generation != reference.generation {
                    await applyRetaining(.taskBound(reference.itemID, generation: reference.generation, taskIdentifier: reference.taskIdentifier))
                }
            } else {
                let keepsResumeData = record.generation == reference.generation && Self.isStopped(record.phase)
                await stopTask(reference.taskIdentifier, of: reference.itemID, producingResumeData: keepsResumeData)
                stopped.insert(reference.taskIdentifier)
            }
        }

        let liveIdentifiers = Set(tasks.map(\.taskIdentifier))
        for record in sortedRecords() {
            guard let stopping = record.stoppingBinding, !stopped.contains(stopping.taskIdentifier) else { continue }
            if liveIdentifiers.contains(stopping.taskIdentifier) {
                await stopTask(stopping.taskIdentifier, of: record.id, producingResumeData: record.phase != .removing)
            } else {
                await applyRetaining(.stopAcknowledged(record.id, taskIdentifier: stopping.taskIdentifier))
            }
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
                    startFinalization(record.id, generation: record.generation, captured: captured)
                }
            default:
                guard record.phase.isAwaitingTransfer, record.journal != .captured else { continue }
                if !adopted.contains(AttemptKey(id: record.id, generation: record.generation)) {
                    orphanCandidates[record.id] = record.generation
                }
            }
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
            guard let reference = task.reference else { continue }
            live[AttemptKey(id: reference.itemID, generation: reference.generation)] = reference.taskIdentifier
        }
        var complete = true
        for key in orphanCandidates.map({ AttemptKey(id: $0.key, generation: $0.value) }).sorted() {
            guard let record = machine?.records[key.id], record.generation == key.generation,
                  record.phase.isAwaitingTransfer, record.journal != .captured else {
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
                await self.receive(event)
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

    /// Stops observing and ends snapshot streams. The storage claim is released now, or, while
    /// leases are outstanding, when the last one ends: no other manager can own the root while
    /// a leased file must stay on disk. Unapplied session events stay unacknowledged.
    private func runDetach() async {
        guard lifecycle == .running else { return }
        lifecycle = .detached
        await teardown(releaseClaim: leases.isEmpty)
    }

    private func teardown(releaseClaim: Bool) async {
        for consumer in consumers { consumer.cancel() }
        consumers = []
        for timer in retryTimers.values { timer.cancel() }
        retryTimers = [:]
        for finalization in finalizations.values { finalization.cancel() }
        finalizations = [:]
        flushTask?.cancel()
        flushTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
        if releaseClaim { await releaseClaimIfHeld() }
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

    /// Retries retained events and failed removals, throwing ``DownloadError/persistenceFailed``
    /// when events are still waiting for an index write.
    func flushPendingWork() async throws {
        try await serialized { [self] in try await self.runFlush() }
    }

    private func runFlush() async throws {
        try requireRunning()
        if !retained.isEmpty || !inbox.isEmpty { throw DownloadError.persistenceFailed }
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

    /// Appends one session event to the ordered inbox and applies as much of it as possible.
    func receive(_ event: TransferSessionEvent) async {
        _ = try? await serialized { [self] in await self.enqueueSessionEvent(event) }
    }

    private func enqueueSessionEvent(_ event: TransferSessionEvent) async {
        inbox.append(event)
        await drainInbox()
    }

    /// Applies inbox entries in order until one cannot be committed, then acknowledges the
    /// applied prefix to the session.
    private func drainInbox() async {
        guard lifecycle == .running else { return }
        var applied: UInt64?
        while let head = inbox.first {
            guard await process(head) else { break }
            inbox.removeFirst()
            applied = head.sequence
        }
        if let applied, let session { await session.acknowledge(through: applied) }
    }

    private func process(_ envelope: TransferSessionEvent) async -> Bool {
        switch envelope.payload {
        case .transfer(let event):
            let committed = await apply(event: .transfer(event))
            return committed || (!event.isTerminal && lifecycle == .running)
        case .backlogDelivered:
            return await resolveOrphanCandidates()
        case .backgroundEventsFinished:
            if let backgroundEvents { await backgroundEvents.eventsApplied() }
            return true
        }
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
        !retained.isEmpty || !inbox.isEmpty || !failedRemovals.isEmpty
    }

    /// Bounded in-process recovery: one attempt per step, never a loop.
    private func runPendingWorkIfNeeded() async {
        guard lifecycle == .running, hasPendingWork else { return }
        if !retained.isEmpty {
            let batch = retained
            retained = []
            for event in batch { await applyRetaining(event) }
        }
        for id in failedRemovals.sorted() {
            await completeRemovalIfUnleased(id)
        }
        if !inbox.isEmpty { await drainInbox() }
    }

    var pendingWorkCount: Int { retained.count + inbox.count + failedRemovals.count }

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
            case .cancelTask(let id, let taskIdentifier, let producingResumeData):
                await stopTask(taskIdentifier, of: id, producingResumeData: producingResumeData)
            case .finalize(let id, let generation, let captured):
                startFinalization(id, generation: generation, captured: captured)
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
    /// generation-checked event; one finalisation per attempt at a time.
    private func startFinalization(_ id: DownloadID, generation: UInt64, captured: RelativePath) {
        let key = AttemptKey(id: id, generation: generation)
        guard finalizations[key] == nil, lifecycle == .running || lifecycle == .starting,
              let layout, let record = machine?.records[id] else { return }
        let request = FinalizationRequest(
            id: id,
            generation: generation,
            stagingPath: captured,
            destination: .media(generation: generation),
            storageRoot: layout.root,
            capturedBytes: record.bytesWritten,
            validators: record.validators,
            expectedLength: record.request.expectedLength,
            checksum: record.request.checksum
        )
        let finalizer = self.finalizer
        finalizations[key] = Task { [weak self] in
            let result = await finalizer.finalize(request)
            await self?.finalizationEnded(id, generation: generation, result: result)
        }
    }

    private func finalizationEnded(_ id: DownloadID, generation: UInt64, result: FinalizationResult) async {
        switch result {
        case .finalized(let finalPath, let integrity):
            await ingest(.finalized(id, generation: generation, finalPath: finalPath, integrity: integrity))
        case .failed(let failure):
            await ingest(.finalizationFailed(id, generation: generation, failure))
        case .deferred:
            break
        }
        finalizations[AttemptKey(id: id, generation: generation)] = nil
    }

    var finalizationsInFlight: Int { finalizations.count }

    private func discard(_ path: RelativePath) async {
        guard let layout else { return }
        try? await dependencies.fileSystem.removeItem(at: layout.url(for: path))
    }

    /// Deletes a tombstoned item's files once no lease protects them. The pending removal is
    /// kept until the record's deletion is committed; a failed file deletion or index write is
    /// retried at the next step.
    private func completeRemovalIfUnleased(_ id: DownloadID) async {
        guard lifecycle == .running, leases[id, default: []].isEmpty, let pending = pendingRemovals[id], let layout else { return }
        for path in pending.paths {
            do {
                try await dependencies.fileSystem.removeItem(at: layout.url(for: path))
            } catch {
                failedRemovals.insert(id)
                return
            }
        }
        if await apply(event: .removalFinished(id, generation: pending.generation)) {
            pendingRemovals[id] = nil
            failedRemovals.remove(id)
        } else {
            failedRemovals.insert(id)
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
            leases[id, default: []].insert(token)
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

    func endAccess(_ lease: LocalFileLease) async {
        _ = try? await serialized { [self] in await self.runEndAccess(lease) }
    }

    private func runEndAccess(_ lease: LocalFileLease) async {
        leases[lease.id]?.remove(lease.token)
        if leases[lease.id]?.isEmpty == true { leases[lease.id] = nil }
        switch lifecycle {
        case .running:
            await completeRemovalIfUnleased(lease.id)
        case .detached:
            // A detached owner never deletes: the next owner finishes removals on its start.
            if leases.isEmpty { await releaseClaimIfHeld() }
        case .idle, .starting:
            break
        }
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
