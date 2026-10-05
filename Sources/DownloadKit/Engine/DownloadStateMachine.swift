//
//  DownloadStateMachine.swift
//  DownloadKit
//
//  The pure transition rules. No I/O, no clocks, no randomness: every input (time, jitter,
//  path status) is passed in, and every side effect is returned as data.
//

import Foundation

struct DownloadStateMachine: Sendable, Equatable {

    enum Command: Sendable, Equatable {
        case enqueue(DownloadRequest)
        case pause(DownloadID)
        case resume(DownloadID)
        case cancel(DownloadID)
        case retry(DownloadID)
        case remove(DownloadID)
        case setDefaultPolicy(NetworkPolicy)
        case setPolicy(NetworkPolicy?, DownloadID)
        case updateSource(URL, DownloadID)
    }

    enum Event: Sendable, Equatable {
        case transfer(TransferEvent)
        case taskBound(DownloadID, generation: UInt64, taskIdentifier: Int)
        case submissionFailed(DownloadID, generation: UInt64, TransferFailure)
        case retryDue(DownloadID, generation: UInt64)
        case finalized(DownloadID, generation: UInt64, finalPath: RelativePath, integrity: IntegrityRecord)
        case finalizationFailed(DownloadID, generation: UInt64, TransferFailure)
        case removalFinished(DownloadID, generation: UInt64)
        case fileMissing(DownloadID, generation: UInt64)
        case fileCorrupt(DownloadID, generation: UInt64)
        /// Reconciliation established that no task exists for this generation.
        case orphanedIntent(DownloadID, generation: UInt64)
        /// The session accepted the cancellation of the task in the record's stopping binding,
        /// or reconciliation found that task gone.
        case stopAcknowledged(DownloadID, taskIdentifier: Int)
        case pathChanged(NetworkPathStatus)
        /// A queued file deletion was verified; its cleanup intent is closed.
        case cleanupFinished(RelativePath)
    }

    enum Effect: Sendable, Equatable {
        case submit(TransferSubmission)
        case cancelTask(DownloadID, taskIdentifier: Int, producingResumeData: Bool)
        case finalize(DownloadID, generation: UInt64, captured: RelativePath)
        case discardFile(RelativePath)
        case deleteOwnedFiles(DownloadID, generation: UInt64, paths: [RelativePath])
        case scheduleRetry(DownloadID, generation: UInt64, at: Date)
        case unscheduleRetry(DownloadID)
    }

    struct Outcome: Sendable, Equatable {
        var effects: [Effect] = []
        var changed: Set<DownloadID> = []
        var deleted: Set<DownloadID> = []
        var globalsChanged = false
        /// Paths added to or removed from the persisted cleanup intent.
        var cleanupQueued: Set<RelativePath> = []
        var cleanupCompleted: Set<RelativePath> = []
        /// True when an event was rejected because its generation (or record) is gone.
        var ignoredStale = false

        var hasStateChanges: Bool {
            !changed.isEmpty || !deleted.isEmpty || globalsChanged || !cleanupQueued.isEmpty || !cleanupCompleted.isEmpty
        }
    }

    private(set) var records: [DownloadID: IndexRecord]
    private(set) var nextGeneration: UInt64
    private(set) var defaultPolicy: NetworkPolicy
    private(set) var pathStatus: NetworkPathStatus?
    /// Files queued for deletion and not yet verified deleted (persisted).
    private(set) var cleanup: Set<RelativePath>
    /// Attempts whose task may exist although no binding proves it: every restored attempt
    /// that expects a transfer, until reconciliation adopts its task, applies its events or
    /// proves it gone, and every submission until its binding is written. A nil binding on
    /// such an attempt is not proof that the attempt ended, so path and policy changes only
    /// change its explanation and never create a replacement.
    private(set) var unconfirmed: [DownloadID: UInt64] = [:]
    /// Policy changes held back for an unconfirmed attempt, applied once it is resolved
    /// (persisted as ``IndexRecord/policyChangeDeferred``).
    private(set) var deferredResubmissions: Set<DownloadID> = []
    /// Resume or retry commands for a stopped attempt that is still unconfirmed. The stopped
    /// state is kept and no replacement is created until the old attempt's disposition is
    /// known: its task is found (it is then adopted as the restarted attempt, unless a policy
    /// change is held, which restarts it under the current policy), its completion arrives (it
    /// is then finalised), or its end is proven (only then a new attempt starts). Persisted as
    /// ``IndexRecord/restartDeferred``; the stop itself as ``IndexRecord/stoppedWhileUnconfirmed``,
    /// so all three survive a relaunch.
    private(set) var deferredRestarts: Set<DownloadID> = []
    let sessionIdentifier: String
    let retryPolicy: RetryPolicy

    init(contents: IndexContents?, sessionIdentifier: String, defaultPolicy: NetworkPolicy, retryPolicy: RetryPolicy) {
        var records: [DownloadID: IndexRecord] = [:]
        var unconfirmed: [DownloadID: UInt64] = [:]
        for var record in contents?.records ?? [] {
            if record.journal == .captured, record.finalizationDestination == nil, record.phase != .removing {
                // Written before the destination was recorded: it is still implied by the
                // capturing generation.
                record.finalizationDestination = .media(generation: record.generation)
            }
            if record.phase.isAwaitingTransfer, record.journal != .captured {
                unconfirmed[record.id] = record.generation
            }
            if record.stoppedWhileUnconfirmed, record.binding == nil, record.journal != .captured, Self.isStopped(record.phase) {
                // Stopped before its task was confirmed, in an earlier process: still unproven.
                unconfirmed[record.id] = record.generation
                if record.restartDeferred { deferredRestarts.insert(record.id) }
            }
            if record.policyChangeDeferred, unconfirmed[record.id] == record.generation {
                deferredResubmissions.insert(record.id)
            }
            records[record.id] = record
        }
        self.records = records
        self.unconfirmed = unconfirmed
        self.cleanup = Set(contents?.cleanupPaths ?? [])
        let highest = records.values.map(\.generation).max() ?? 0
        self.nextGeneration = max(contents?.nextGeneration ?? 1, highest + 1)
        self.defaultPolicy = contents?.defaultPolicy ?? defaultPolicy
        self.pathStatus = nil
        self.sessionIdentifier = sessionIdentifier
        self.retryPolicy = retryPolicy
    }

    // MARK: Queries

    func effectivePolicy(for record: IndexRecord) -> NetworkPolicy {
        record.policy ?? defaultPolicy
    }

    /// A request from zero for the current attempt, after the server refused its continuation
    /// on `refusedTask`: same generation, no resume data, the persisted source URL. `nil` when
    /// that attempt is not current any more, no longer awaits a transfer, holds a capture or is
    /// bound to another task.
    func replacementSubmission(for id: DownloadID, generation: UInt64, refusedTask: Int) -> TransferSubmission? {
        guard let record = records[id], record.generation == generation, record.phase.isAwaitingTransfer,
              record.journal != .captured else { return nil }
        if let binding = record.binding, binding.taskIdentifier != refusedTask { return nil }
        return TransferSubmission(
            itemID: id,
            generation: generation,
            url: record.request.sourceURL,
            policy: effectivePolicy(for: record),
            resumeDataPath: nil,
            expectedLength: record.request.expectedLength
        )
    }

    func snapshot(for id: DownloadID) -> DownloadSnapshot? {
        records[id]?.snapshot
    }

    func snapshots() -> [DownloadSnapshot] {
        records.values
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            .map(\.snapshot)
    }

    // MARK: Commands

    mutating func handle(_ command: Command, now: Date) throws -> Outcome {
        var outcome = Outcome()
        switch command {
        case .enqueue(let request):
            try enqueue(request, now: now, into: &outcome)

        case .pause(let id):
            var record = try existing(id)
            deferredRestarts.remove(id)
            guard record.phase.isTransferring else { break }
            stopTransfer(&record, producingResumeData: true, into: &outcome)
            record.phase = .paused
            save(record, now: now, into: &outcome)

        case .resume(let id):
            let record = try existing(id)
            guard record.phase == .paused else { break }
            guard !deferRestart(record) else { break }
            submit(id, now: now, into: &outcome)

        case .cancel(let id):
            var record = try existing(id)
            deferredRestarts.remove(id)
            guard record.phase.isTransferring || record.phase == .paused else { break }
            stopTransfer(&record, producingResumeData: true, into: &outcome)
            record.phase = .failed(DownloadFailure(kind: .cancelled))
            save(record, now: now, into: &outcome)

        case .retry(let id):
            var record = try existing(id)
            guard acceptsRetry(record) else { break }
            stopTransfer(&record, producingResumeData: true, into: &outcome)
            record.automaticRetryCount = 0
            save(record, now: now, into: &outcome)
            guard !deferRestart(record) else { break }
            submit(id, now: now, into: &outcome)

        case .remove(let id):
            deferredRestarts.remove(id)
            deferredResubmissions.remove(id)
            guard var record = records[id], record.phase != .removing else { break }
            stopTransfer(&record, producingResumeData: false, into: &outcome)
            record.generation = allocateGeneration()
            record.phase = .removing
            save(record, now: now, into: &outcome)
            outcome.effects.append(.deleteOwnedFiles(id, generation: record.generation, paths: record.ownedPaths))

        case .setDefaultPolicy(let policy):
            guard policy != defaultPolicy else { break }
            defaultPolicy = policy
            outcome.globalsChanged = true
            for id in records.keys.sorted() where records[id]?.policy == nil {
                resubmitForPolicyChange(id, now: now, into: &outcome)
            }

        case .setPolicy(let policy, let id):
            var record = try existing(id)
            guard record.phase != .removing else { throw DownloadError.itemBeingRemoved(id) }
            guard record.policy != policy else { break }
            let previous = effectivePolicy(for: record)
            record.policy = policy
            save(record, now: now, into: &outcome)
            if effectivePolicy(for: record) != previous {
                resubmitForPolicyChange(id, now: now, into: &outcome)
            }

        case .updateSource(let url, let id):
            var record = try existing(id)
            try validateSource(url, id)
            guard record.request.sourceURL != url else { break }
            record.request.sourceURL = url
            save(record, now: now, into: &outcome)
        }
        persistDeferredState(now: now, into: &outcome)
        return outcome
    }

    private func validateSource(_ url: URL, _ id: DownloadID) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedURL(id)
        }
        guard url.user == nil, url.password == nil else { throw DownloadError.credentialsInURL(id) }
    }

    private mutating func enqueue(_ request: DownloadRequest, now: Date, into outcome: inout Outcome) throws {
        try validateSource(request.url, request.id)
        let identity = RequestIdentity(request)
        guard var record = records[request.id] else {
            records[request.id] = IndexRecord(
                unchecked: request.id,
                request: identity,
                metadata: request.metadata,
                policy: request.policy,
                phase: .queued,
                generation: 0,
                automaticRetryCount: 0,
                retryAt: nil,
                binding: nil,
                stoppingBinding: nil,
                bytesWritten: 0,
                expectedBytes: request.expectedLength,
                validators: nil,
                integrity: nil,
                journal: .notStarted,
                stagingPath: nil,
                finalPath: nil,
                resumeDataPath: nil,
                createdAt: now,
                updatedAt: now
            )
            submit(request.id, now: now, into: &outcome)
            return
        }
        guard record.phase != .removing else { throw DownloadError.itemBeingRemoved(request.id) }
        guard record.request.hasSameContent(as: identity) else { throw DownloadError.conflictingRequest(request.id) }

        var touched = false
        if record.request.sourceURL != request.url {
            record.request.sourceURL = request.url
            touched = true
        }
        if record.metadata != request.metadata {
            record.metadata = request.metadata
            touched = true
        }
        if touched { save(record, now: now, into: &outcome) }
        if record.phase == .missing { submit(request.id, now: now, into: &outcome) }
    }

    // MARK: Events

    mutating func handle(_ event: Event, now: Date, jitter: Double) -> Outcome {
        var outcome = Outcome()
        switch event {
        case .transfer(let transfer):
            handleTransfer(transfer, now: now, jitter: jitter, into: &outcome)

        case .taskBound(let id, let generation, let taskIdentifier):
            if let record = records[id], record.generation == generation, isStoppedAndUnconfirmed(record) {
                stoppedAttemptFound(record, taskIdentifier: taskIdentifier, now: now, into: &outcome)
                break
            }
            guard var record = current(id, generation, &outcome), record.phase.isAwaitingTransfer else {
                // A task nobody wants any more must not keep running.
                outcome.effects.append(.cancelTask(id, taskIdentifier: taskIdentifier, producingResumeData: false))
                break
            }
            unconfirmed[id] = nil
            let binding = TaskBinding(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier, generation: generation)
            if record.binding != binding {
                record.binding = binding
                save(record, now: now, into: &outcome)
            }
            if deferredResubmissions.remove(id) != nil {
                // A policy change waited for this attempt to be known: apply it now.
                resubmitForPolicyChange(id, now: now, into: &outcome)
            }

        case .submissionFailed(let id, let generation, let failure):
            applyFailure(id, generation, failure, now: now, jitter: jitter, into: &outcome)

        case .retryDue(let id, let generation):
            guard let record = current(id, generation, &outcome), case .waiting(.retryScheduled) = record.phase else { break }
            submit(id, now: now, into: &outcome)

        case .finalized(let id, let generation, let finalPath, let integrity):
            guard var record = current(id, generation, &outcome), record.journal == .captured else { break }
            // Linearisation point: the completion takes effect only if no stop was committed
            // before this result. A paused or cancelled record keeps the validated file under
            // its planned destination and its intent; resume or retry finalises it again
            // (idempotently) and only then publishes the completion.
            guard record.phase == .active else { break }
            if let previous = record.finalPath, previous != finalPath { queueDiscard(previous, into: &outcome) }
            if let resume = record.resumeDataPath { queueDiscard(resume, into: &outcome) }
            if let destination = record.finalizationDestination, destination != finalPath { queueDiscard(destination, into: &outcome) }
            record.phase = .completed(at: now)
            record.journal = .committed
            record.stagingPath = nil
            record.finalizationDestination = nil
            record.finalPath = finalPath
            record.resumeDataPath = nil
            record.bytesWritten = integrity.verifiedLength
            record.expectedBytes = integrity.verifiedLength
            record.integrity = integrity
            record.binding = nil
            record.retryAt = nil
            save(record, now: now, into: &outcome)

        case .finalizationFailed(let id, let generation, let failure):
            guard var record = current(id, generation, &outcome), record.journal == .captured else { break }
            if let captured = record.stagingPath { queueDiscard(captured, into: &outcome) }
            if let destination = record.finalizationDestination, destination != record.finalPath { queueDiscard(destination, into: &outcome) }
            record.stagingPath = nil
            record.finalizationDestination = nil
            // The capture of this attempt is consumed: a replay of its completion is ignored.
            record.journal = .rejected
            // A stop committed before this result keeps its intent.
            if record.phase == .active { record.phase = .failed(failure.downloadFailure) }
            save(record, now: now, into: &outcome)

        case .removalFinished(let id, let generation):
            guard let record = current(id, generation, &outcome), record.phase == .removing else { break }
            records[id] = nil
            outcome.changed.remove(id)
            outcome.deleted.insert(id)

        case .fileMissing(let id, let generation):
            guard var record = current(id, generation, &outcome), case .completed = record.phase else { break }
            record.phase = .missing
            record.finalPath = nil
            record.integrity = nil
            record.journal = .notStarted
            record.bytesWritten = 0
            save(record, now: now, into: &outcome)

        case .fileCorrupt(let id, let generation):
            guard var record = current(id, generation, &outcome), case .completed = record.phase else { break }
            // The file stays recorded so a later successful attempt can replace it safely.
            record.phase = .failed(DownloadFailure(kind: .integrity))
            save(record, now: now, into: &outcome)

        case .orphanedIntent(let id, let generation):
            if let record = records[id], record.generation == generation, isStoppedAndUnconfirmed(record) {
                stoppedAttemptEnded(record, now: now, into: &outcome)
                break
            }
            guard let record = current(id, generation, &outcome), record.phase.isAwaitingTransfer, record.journal != .captured else { break }
            unconfirmed[id] = nil
            deferredResubmissions.remove(id)
            submit(id, now: now, into: &outcome)

        case .stopAcknowledged(let id, let taskIdentifier):
            guard var record = records[id], record.stoppingBinding?.taskIdentifier == taskIdentifier else { break }
            record.stoppingBinding = nil
            save(record, now: now, into: &outcome)

        case .pathChanged(let status):
            pathStatus = status
            for id in records.keys.sorted() {
                explain(id, status: status, now: now, into: &outcome)
            }

        case .cleanupFinished(let path):
            guard cleanup.remove(path) != nil else { break }
            outcome.cleanupCompleted.insert(path)
        }
        persistDeferredState(now: now, into: &outcome)
        return outcome
    }

    private mutating func handleTransfer(_ event: TransferEvent, now: Date, jitter: Double, into outcome: inout Outcome) {
        switch event {
        case .progress(let reference, let bytes, let expected):
            if let record = records[reference.itemID], record.generation == reference.generation, isStoppedAndUnconfirmed(record) {
                stoppedAttemptFound(record, taskIdentifier: reference.taskIdentifier, now: now, into: &outcome)
                break
            }
            guard var record = current(reference.itemID, reference.generation, &outcome),
                  record.phase.isAwaitingTransfer, record.journal != .captured else { break }
            record.phase = .active
            record.bytesWritten = max(0, bytes)
            if let expected, expected > 0 { record.expectedBytes = expected }
            let discovered = record.binding == nil
            if discovered {
                record.binding = TaskBinding(sessionIdentifier: sessionIdentifier, taskIdentifier: reference.taskIdentifier, generation: reference.generation)
            }
            save(record, now: now, into: &outcome)
            if discovered {
                // Progress proves the task like a binding does: a policy change held for the
                // unconfirmed attempt is enforced now, once.
                unconfirmed[record.id] = nil
                if deferredResubmissions.remove(record.id) != nil {
                    resubmitForPolicyChange(record.id, now: now, into: &outcome)
                }
            }

        case .waiting(let reference, let reason):
            if let record = records[reference.itemID], record.generation == reference.generation, isStoppedAndUnconfirmed(record) {
                stoppedAttemptFound(record, taskIdentifier: reference.taskIdentifier, now: now, into: &outcome)
                break
            }
            guard var record = current(reference.itemID, reference.generation, &outcome),
                  record.phase.isAwaitingTransfer, record.journal != .captured else { break }
            // Only the manager schedules retries; a session cannot claim one.
            let honest: WaitReason = reason.isRetrySchedule ? .unknown : reason
            guard record.phase != .waiting(honest) else { break }
            record.phase = .waiting(honest)
            save(record, now: now, into: &outcome)

        case .finished(let reference, let captured, let bytes, let validators):
            guard var record = current(reference.itemID, reference.generation, &outcome) else {
                // Stale completion: keep the bytes only if some record still owns the path.
                discardUnowned(captured, into: &outcome)
                break
            }
            if record.journal == .captured {
                // A replay of the capture already held is a no-op; a second capture for the
                // same attempt is discarded unless something owns it.
                if record.stagingPath != captured { discardUnowned(captured, into: &outcome) }
                break
            }
            if record.journal == .rejected || record.journal == .committed {
                // This attempt's capture was already received and consumed (validated or
                // rejected): one capture per attempt, a replay never captures again.
                discardUnowned(captured, into: &outcome)
                break
            }
            // A restart asked for while this attempt was unconfirmed is answered by its capture.
            let restartWaited = deferredRestarts.remove(record.id) != nil
            let finalizeNow: Bool
            switch record.phase {
            case .queued, .active, .waiting, .paused:
                if case .waiting(.retryScheduled) = record.phase { outcome.effects.append(.unscheduleRetry(record.id)) }
                finalizeNow = true
            case .failed:
                // Cancelled (or failed) at this generation: retain the bytes with the record
                // without publishing a completion. Retry finalises them.
                finalizeNow = restartWaited
            case .completed, .missing, .removing:
                discardUnowned(captured, into: &outcome)
                return
            }
            if finalizeNow { record.phase = .active }
            unconfirmed[record.id] = nil
            deferredResubmissions.remove(record.id)
            record.journal = .captured
            record.stagingPath = captured
            // The extension comes only from response evidence a real transfer recorded.
            record.finalizationDestination = .media(
                generation: record.generation,
                fileExtension: validators.flatMap { MediaFileExtension.infer(mediaType: $0.mediaType, sourceURL: record.request.sourceURL) }
            )
            record.bytesWritten = max(0, bytes)
            record.validators = validators
            record.binding = nil
            record.retryAt = nil
            save(record, now: now, into: &outcome)
            if finalizeNow {
                outcome.effects.append(.finalize(record.id, generation: record.generation, captured: captured))
            }

        case .failed(let reference, let failure):
            applyFailure(reference.itemID, reference.generation, failure, now: now, jitter: jitter, into: &outcome)

        case .resumeDataCaptured(let reference, let path):
            guard var record = current(reference.itemID, reference.generation, &outcome) else {
                discardUnowned(path, into: &outcome)
                break
            }
            switch record.phase {
            case .paused, .failed:
                if let previous = record.resumeDataPath, previous != path { queueDiscard(previous, into: &outcome) }
                record.resumeDataPath = path
                save(record, now: now, into: &outcome)
            default:
                discardUnowned(path, into: &outcome)
            }
        }
    }

    private mutating func applyFailure(_ id: DownloadID, _ generation: UInt64, _ failure: TransferFailure, now: Date, jitter: Double, into outcome: inout Outcome) {
        if let record = records[id], record.generation == generation, isStoppedAndUnconfirmed(record) {
            // The session reported the end of a stopped attempt that was never confirmed.
            stoppedAttemptEnded(record, now: now, into: &outcome)
            return
        }
        // Failures for paused or cancelled items are the expected echo of our own cancel.
        guard var record = current(id, generation, &outcome), record.phase.isAwaitingTransfer, record.journal != .captured else { return }
        record.binding = nil
        // The session reported the end of this attempt: it is no longer unconfirmed.
        unconfirmed[id] = nil
        let policyChangeWaited = deferredResubmissions.remove(id) != nil
        switch failure.classification {
        case .policyWait:
            record.phase = .waiting(.networkPolicy)
        case .networkTransient where record.automaticRetryCount < retryPolicy.maximumAutomaticRetries:
            let delay = retryPolicy.delay(forRetry: record.automaticRetryCount, jitter: jitter, retryAfter: failure.retryAfter)
            let dueAt = now.addingTimeInterval(delay)
            record.automaticRetryCount += 1
            record.retryAt = dueAt
            record.phase = .waiting(.retryScheduled(at: dueAt))
            outcome.effects.append(.scheduleRetry(id, generation: record.generation, at: dueAt))
        default:
            record.retryAt = nil
            record.phase = .failed(failure.downloadFailure)
        }
        save(record, now: now, into: &outcome)
        if policyChangeWaited, record.phase == .waiting(.networkPolicy) {
            // The attempt ended on the old policy; the held-back change gets its one attempt.
            submit(id, now: now, into: &outcome)
        }
    }

    private mutating func explain(_ id: DownloadID, status: NetworkPathStatus, now: Date, into outcome: inout Outcome) {
        guard var record = records[id], record.journal != .captured else { return }
        switch record.phase {
        case .queued, .active, .waiting(.networkPolicy), .waiting(.connectivity):
            break
        default:
            return
        }
        switch effectivePolicy(for: record).evaluate(status) {
        case .waiting(let reason):
            guard record.phase != .waiting(reason) else { return }
            record.phase = .waiting(reason)
            save(record, now: now, into: &outcome)
        case .allowed:
            guard case .waiting = record.phase else { return }
            if record.binding == nil, !isUnconfirmed(record) {
                // The earlier attempt provably ended on a policy refusal; start a new one, once.
                submit(id, now: now, into: &outcome)
            } else {
                // A bound attempt, or one whose task may still exist: explanation only.
                record.phase = .queued
                save(record, now: now, into: &outcome)
            }
        }
    }

    // MARK: Helpers

    private func existing(_ id: DownloadID) throws -> IndexRecord {
        guard let record = records[id] else { throw DownloadError.unknownItem(id) }
        return record
    }

    /// Whether `record`'s current attempt may still have a task although no binding shows it.
    func isUnconfirmed(_ record: IndexRecord) -> Bool {
        unconfirmed[record.id] == record.generation
    }

    private func current(_ id: DownloadID, _ generation: UInt64, _ outcome: inout Outcome) -> IndexRecord? {
        guard let record = records[id], record.generation == generation else {
            outcome.ignoredStale = true
            return nil
        }
        return record
    }

    /// Whether `record` was stopped (paused or cancelled) while its attempt was unconfirmed:
    /// a task of that attempt may still run, and its completion may still arrive.
    func isStoppedAndUnconfirmed(_ record: IndexRecord) -> Bool {
        guard isUnconfirmed(record), record.binding == nil, record.journal != .captured else { return false }
        return Self.isStopped(record.phase)
    }

    /// Holds a resume or retry of a stopped, unconfirmed attempt instead of replacing it.
    /// Returns true when the restart was deferred.
    private mutating func deferRestart(_ record: IndexRecord) -> Bool {
        guard isStoppedAndUnconfirmed(record) else { return false }
        deferredRestarts.insert(record.id)
        return true
    }

    /// The task of a stopped, unconfirmed attempt was found. A restart asked for meanwhile
    /// adopts it; otherwise the stop is enforced against exactly that task.
    ///
    /// A policy change held for the attempt is consumed here, exactly once. The found task was
    /// created under the old policy and cannot be narrowed, so it is never adopted then: it is
    /// cancelled, and when a restart was asked for a new attempt starts under the current policy.
    private mutating func stoppedAttemptFound(_ record: IndexRecord, taskIdentifier: Int, now: Date, into outcome: inout Outcome) {
        var record = record
        unconfirmed[record.id] = nil
        let binding = TaskBinding(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier, generation: record.generation)
        let policyChanged = deferredResubmissions.remove(record.id) != nil
        let restartWaited = deferredRestarts.remove(record.id) != nil
        if restartWaited, !policyChanged {
            record.phase = submissionPhase(for: record)
            record.binding = binding
            save(record, now: now, into: &outcome)
            return
        }
        record.stoppingBinding = binding
        outcome.effects.append(.cancelTask(record.id, taskIdentifier: taskIdentifier, producingResumeData: true))
        save(record, now: now, into: &outcome)
        if restartWaited {
            submit(record.id, now: now, into: &outcome)
        }
    }

    /// A stopped, unconfirmed attempt provably ended without a capture. Only now does a
    /// deferred restart create a new attempt.
    private mutating func stoppedAttemptEnded(_ record: IndexRecord, now: Date, into outcome: inout Outcome) {
        unconfirmed[record.id] = nil
        // A new attempt (if any) is created under the current policy anyway.
        deferredResubmissions.remove(record.id)
        if deferredRestarts.remove(record.id) != nil {
            submit(record.id, now: now, into: &outcome)
        }
    }

    static func isStopped(_ phase: RecordPhase) -> Bool {
        switch phase {
        case .paused, .failed: return true
        default: return false
        }
    }

    /// Writes the in-memory dispositions that must survive a relaunch into their records:
    /// ``IndexRecord/stoppedWhileUnconfirmed``, ``IndexRecord/restartDeferred`` and
    /// ``IndexRecord/policyChangeDeferred``. Runs at the end of every command and event, so
    /// they are committed in the same change set as the transition that set or cleared them.
    /// Entries that no longer describe an unconfirmed attempt are dropped first.
    private mutating func persistDeferredState(now: Date, into outcome: inout Outcome) {
        for id in deferredRestarts where !(records[id].map(isStoppedAndUnconfirmed) ?? false) {
            deferredRestarts.remove(id)
        }
        for id in deferredResubmissions where !(records[id].map(isUnconfirmed) ?? false) {
            deferredResubmissions.remove(id)
        }
        for id in records.keys.sorted() {
            guard var record = records[id] else { continue }
            let stopped = isStoppedAndUnconfirmed(record)
            let restart = deferredRestarts.contains(id)
            let policy = deferredResubmissions.contains(id)
            guard record.stoppedWhileUnconfirmed != stopped || record.restartDeferred != restart || record.policyChangeDeferred != policy else { continue }
            record.stoppedWhileUnconfirmed = stopped
            record.restartDeferred = restart
            record.policyChangeDeferred = policy
            save(record, now: now, into: &outcome)
        }
    }

    private func acceptsRetry(_ record: IndexRecord) -> Bool {
        switch record.phase {
        case .failed, .missing:
            return true
        case .waiting(.retryScheduled):
            return true
        case .waiting:
            return record.binding == nil && record.journal != .captured && !isUnconfirmed(record)
        default:
            return false
        }
    }

    private mutating func allocateGeneration() -> UInt64 {
        let generation = nextGeneration
        nextGeneration += 1
        return generation
    }

    private func submissionPhase(for record: IndexRecord) -> RecordPhase {
        if let pathStatus, case .waiting(let reason) = effectivePolicy(for: record).evaluate(pathStatus) {
            return .waiting(reason)
        }
        return .queued
    }

    /// Ends the current attempt. The binding moves to ``IndexRecord/stoppingBinding`` and
    /// stays persisted until the session acknowledges the cancellation, so a stop interrupted
    /// by process exit is enforced again by reconciliation.
    private func stopTransfer(_ record: inout IndexRecord, producingResumeData: Bool, into outcome: inout Outcome) {
        if case .waiting(.retryScheduled) = record.phase {
            outcome.effects.append(.unscheduleRetry(record.id))
        }
        if let binding = record.binding {
            outcome.effects.append(.cancelTask(record.id, taskIdentifier: binding.taskIdentifier, producingResumeData: producingResumeData))
            record.stoppingBinding = binding
        }
        record.binding = nil
        record.retryAt = nil
    }

    private mutating func resubmitForPolicyChange(_ id: DownloadID, now: Date, into outcome: inout Outcome) {
        if let record = records[id], isStoppedAndUnconfirmed(record) {
            // Stopped while its task may still run under the old policy: hold the change so the
            // task is not adopted under it when a restart finds it.
            deferredResubmissions.insert(id)
            return
        }
        guard var record = records[id], record.phase.isAwaitingTransfer, record.journal != .captured else { return }
        if record.binding == nil, isUnconfirmed(record) {
            // The task, if any, cannot be cancelled yet and its completion may still arrive:
            // hold the change until reconciliation knows the attempt.
            deferredResubmissions.insert(id)
            return
        }
        stopTransfer(&record, producingResumeData: true, into: &outcome)
        save(record, now: now, into: &outcome)
        submit(id, now: now, into: &outcome)
    }

    private mutating func submit(_ id: DownloadID, now: Date, into outcome: inout Outcome) {
        guard var record = records[id] else { return }
        if record.journal == .captured, let captured = record.stagingPath {
            // Captured bytes belong to their generation: recover the pending finalisation
            // instead of starting a transfer that the capture would shadow.
            record.binding = nil
            record.retryAt = nil
            record.phase = .active
            save(record, now: now, into: &outcome)
            outcome.effects.append(.finalize(id, generation: record.generation, captured: captured))
            return
        }
        record.generation = allocateGeneration()
        record.binding = nil
        record.retryAt = nil
        record.phase = submissionPhase(for: record)
        // A new attempt has received no capture yet.
        record.journal = .notStarted
        // Submitted, binding not yet written.
        unconfirmed[id] = record.generation
        let submission = TransferSubmission(
            itemID: id,
            generation: record.generation,
            url: record.request.sourceURL,
            policy: effectivePolicy(for: record),
            resumeDataPath: record.resumeDataPath,
            expectedLength: record.request.expectedLength
        )
        if record.resumeDataPath == nil {
            // A fresh attempt: nothing from an earlier response carries over.
            record.bytesWritten = 0
            record.expectedBytes = record.request.expectedLength
            record.validators = nil
        }
        // Resume data is handed to the session, which owns it from now on.
        record.resumeDataPath = nil
        save(record, now: now, into: &outcome)
        outcome.effects.append(.submit(submission))
    }

    /// Discards `path` only when no record owns it.
    private mutating func discardUnowned(_ path: RelativePath, into outcome: inout Outcome) {
        guard !isOwned(path) else { return }
        queueDiscard(path, into: &outcome)
    }

    /// Whether any record owns `path`.
    func isOwned(_ path: RelativePath) -> Bool {
        records.values.contains { $0.ownedPaths.contains(path) }
    }

    /// Persists the intent to delete `path` in the same commit as the change that released
    /// it, then asks for the deletion. The intent is closed by ``Event/cleanupFinished(_:)``.
    private mutating func queueDiscard(_ path: RelativePath, into outcome: inout Outcome) {
        if cleanup.insert(path).inserted { outcome.cleanupQueued.insert(path) }
        outcome.cleanupCompleted.remove(path)
        outcome.effects.append(.discardFile(path))
    }

    private mutating func save(_ record: IndexRecord, now: Date, into outcome: inout Outcome) {
        var record = record
        record.updatedAt = now
        records[record.id] = record
        outcome.changed.insert(record.id)
    }
}

extension IndexRecord {
    /// The public view of this record.
    var snapshot: DownloadSnapshot {
        let state: DownloadState
        switch phase {
        case .queued: state = .queued
        case .active: state = .active
        case .paused: state = .paused(resumable: resumeDataPath != nil)
        case .waiting(let reason): state = .waiting(reason)
        case .completed(let date): state = .completed(at: date)
        case .failed(let failure): state = .failed(failure)
        case .removing: state = .removing
        case .missing: state = .missing
        }
        return DownloadSnapshot(
            id: id,
            revision: request.revision,
            metadata: metadata,
            state: state,
            bytesWritten: bytesWritten,
            expectedBytes: expectedBytes,
            automaticRetryCount: automaticRetryCount,
            retryAt: retryAt,
            updatedAt: updatedAt
        )
    }
}
