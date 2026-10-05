//
//  DownloadManager.swift
//  DownloadKit
//

import Foundation

/// The host-owned entry point of DownloadKit.
///
/// Lifecycle:
/// 1. Create one manager per storage scope at launch with an explicit
///    ``DownloadConfiguration`` and keep it for the life of the process. There is no shared
///    instance.
/// 2. `try await start()` before any command. Start resolves the storage root, claims it,
///    loads the index and reconciles it with the transfer session. A second manager for the
///    same root or session identifier fails with ``DownloadError/ownerAlreadyActive``.
/// 3. Send commands. Every command and every transfer event is applied in arrival order, one
///    at a time: the index is written before in-memory state changes and before any transfer
///    is started or cancelled.
/// 4. Forward the app delegate's background-session wake to
///    ``handleBackgroundEvents(forSession:completionHandler:)``. It may be called before
///    ``start()`` finishes.
/// 5. ``detach()`` releases the in-process owner without cancelling transfers.
///
/// Releasing a view or ending a snapshot subscription never affects transfers.
///
/// Pause, cancel and remove differ:
/// - pause keeps the record and asks for resume data;
/// - cancel ends the transfer intent and automatic retries, keeping the record and any resume
///   data (the item becomes `failed(.cancelled)`; ``retry(_:)`` restarts it);
/// - remove cancels, tombstones the record with a new generation so no late event can bring it
///   back, then deletes only that item's own files once every ``LocalFileLease`` has ended.
///
/// The package never creates players or configures an audio session.
public final class DownloadManager: Sendable {
    public let configuration: DownloadConfiguration
    let engine: DownloadEngine
    private let backgroundEvents: BackgroundEventsCoordinator
    private let host = EngineHost()

    /// Creates a manager. Captured files are finalised by the package's validating finaliser
    /// (evidence, length, content, optional checksum, then an atomic rename), using the
    /// configuration's file system and clock.
    public convenience init(configuration: DownloadConfiguration, urlRefresher: (any URLRefreshing)? = nil) {
        let dependencies = configuration.dependencies
        self.init(configuration: configuration, urlRefresher: urlRefresher, finalizer: FileFinalizer(fileSystem: dependencies.fileSystem, clock: dependencies.clock))
    }

    init(configuration: DownloadConfiguration, urlRefresher: (any URLRefreshing)?, finalizer: any DownloadFinalizing) {
        self.configuration = configuration
        let backgroundEvents = BackgroundEventsCoordinator()
        self.backgroundEvents = backgroundEvents
        self.engine = DownloadEngine(configuration: configuration, urlRefresher: urlRefresher, finalizer: finalizer, backgroundEvents: backgroundEvents, host: host)
    }

    // MARK: Lifecycle

    /// Restores and reconciles durable state. Must finish before any command.
    ///
    /// Throws ``DownloadError/storageUnavailable``, ``DownloadError/ownerAlreadyActive``,
    /// ``DownloadError/unsupportedSchema(found:supported:)``, ``DownloadError/corruptIndex``,
    /// ``DownloadError/transportUnavailable`` or ``DownloadError/alreadyStarted``. A failed start
    /// changes nothing on disk beyond creating the storage directories and may be retried.
    public func start() async throws {
        try await engine.start()
    }

    /// Releases the in-process owner: stops observing events and ends snapshot streams.
    /// Transfers already handed to the system are not cancelled, and session events not yet
    /// applied stay with the session for the next owner.
    ///
    /// Returns once no file worker of this manager is running any more: a finaliser in flight
    /// is an ownership claim on the root, so detach waits for it to return (a finaliser defers
    /// at ``DownloadConfiguration/finalizationBudget``). The storage claim is then freed when no
    /// ``LocalFileLease`` is outstanding; otherwise it is kept until the last lease ends, so
    /// another manager cannot take over the root and delete a file that is still leased. A
    /// detached manager never deletes files; the next owner finishes pending removals when it
    /// starts.
    public func detach() async {
        await engine.detach()
    }

    /// Accepts the host's background-session wake.
    ///
    /// Call it from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Returns `false`, without keeping the handler, when `identifier` is not this manager's
    /// session identifier; the host stays responsible for it. Otherwise the handler is kept
    /// (even before ``start()`` finished) and called exactly once on the main actor after the
    /// manager has applied every event the system delivered for the wake.
    @MainActor
    @discardableResult
    public func handleBackgroundEvents(forSession identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == configuration.sessionIdentifier else { return false }
        backgroundEvents.register(completionHandler)
        return true
    }

    /// Retries work that is waiting for the index: terminal transfer events and internal
    /// follow-ups whose write was rejected, and file deletions of removed items. The same retry
    /// also runs at the start of every later command.
    ///
    /// Throws ``DownloadError/persistenceFailed`` while events are still waiting for an index
    /// write. A file deletion that keeps failing leaves the item `removing`, or its deletion
    /// intent queued in the index. When start-up reconciliation timed out, this also looks for
    /// the missing tasks again and throws ``DownloadError/reconciliationUnresolved`` while some
    /// are still unaccounted for; their intent and bytes are kept.
    public func flushPendingWork() async throws {
        try await engine.flushPendingWork()
    }

    /// Where start-up reconciliation stands. See ``ReconciliationStatus``.
    public func reconciliationStatus() async -> ReconciliationStatus {
        await engine.reconciliationStatus()
    }

    /// Files under `staging/` and `media/` that no record owns and no queued deletion names,
    /// for example after an interrupted migration or a crash in an adapter. They are reported,
    /// never deleted automatically.
    ///
    /// Throws ``DownloadError/notStarted`` before start and ``DownloadError/storageUnavailable``
    /// when a directory cannot be listed.
    public func unreferencedFiles() async throws -> [RelativePath] {
        try await engine.unreferencedFiles()
    }

    // MARK: Commands

    /// Adds an item, or returns the existing one unchanged when the content matches.
    ///
    /// The same identifier with the same revision, expected length and checksum is idempotent
    /// (a changed URL or metadata is stored, nothing is resubmitted). Any difference in content
    /// throws ``DownloadError/conflictingRequest(_:)``; a completed file is never overwritten
    /// by enqueue.
    @discardableResult
    public func enqueue(_ request: DownloadRequest) async throws -> DownloadSnapshot {
        try await engine.enqueue(request)
    }

    public func pause(_ id: DownloadID) async throws {
        try await engine.run(.pause(id))
    }

    public func resume(_ id: DownloadID) async throws {
        try await engine.run(.resume(id))
    }

    public func cancel(_ id: DownloadID) async throws {
        try await engine.run(.cancel(id))
    }

    /// Starts a new attempt for a failed, missing or retry-waiting item and resets its
    /// automatic retry count. For an `unauthorized` failure the ``URLRefreshing`` is asked for a
    /// fresh URL first.
    public func retry(_ id: DownloadID) async throws {
        try await engine.run(.retry(id))
    }

    /// Removes one item. Removing an unknown item is not an error.
    public func remove(_ id: DownloadID) async throws {
        try await engine.remove([id])
    }

    /// Removes several items, for example a group. Pass member identifiers explicitly; files
    /// are never removed by directory or pattern.
    public func remove(_ ids: [DownloadID]) async throws {
        try await engine.remove(ids)
    }

    /// Persists a new default policy. Items without their own policy that are queued, active or
    /// waiting are resubmitted once under it; paused and failed items use it on their next
    /// attempt.
    public func setDefaultPolicy(_ policy: NetworkPolicy) async throws {
        try await engine.run(.setDefaultPolicy(policy))
    }

    /// Sets or clears (`nil`) one item's policy override.
    public func setPolicy(_ policy: NetworkPolicy?, for id: DownloadID) async throws {
        try await engine.run(.setPolicy(policy, id))
    }

    // MARK: Queries

    /// The persisted default policy, or the configured one when none was persisted.
    public func defaultPolicy() async -> NetworkPolicy {
        await engine.defaultPolicy()
    }

    public func snapshot(for id: DownloadID) async -> DownloadSnapshot? {
        await engine.snapshot(for: id)
    }

    /// The state of `id`, ``DownloadState/notDownloaded`` when no record exists.
    public func state(for id: DownloadID) async -> DownloadState {
        await engine.snapshot(for: id)?.state ?? .notDownloaded
    }

    public func allSnapshots() async -> [DownloadSnapshot] {
        await engine.allSnapshots()
    }

    /// A stream of every item's snapshot, oldest item first.
    ///
    /// Each iteration is one subscription. It yields the current list immediately (this first
    /// value does not count toward ``DownloadConfiguration/snapshotInterval``), then at most
    /// once per interval. It buffers only the newest list, so a slow consumer skips
    /// intermediate lists instead of growing memory. Ending the iteration in any way,
    /// including `break`, unsubscribes and never affects transfers.
    public func snapshots() async -> DownloadSnapshotStream {
        DownloadSnapshotStream(engine: engine)
    }

    // MARK: Local files

    /// Returns a validated completed file and a lease, or why none is available.
    ///
    /// Validation checks the file exists and matches the recorded length. A verifiably absent
    /// file turns the item into ``DownloadState/missing``; a size mismatch fails it with
    /// ``DownloadFailure/Kind/integrity``. When the file cannot be inspected at all (for
    /// example file protection while the device is locked) this throws
    /// ``DownloadError/fileAccessFailed(_:)`` and changes nothing. Nothing is fetched from the
    /// network here.
    public func localFile(for id: DownloadID) async throws -> LocalFileResult {
        try await engine.localFile(for: id)
    }

    /// Ends a lease returned by ``localFile(for:)``. A pending removal completes when the last
    /// lease of the item ends.
    ///
    /// The lease is ended by the manager that issued it, whichever manager this is called on,
    /// so a lease that outlived its (detached or released) manager can be ended through its
    /// successor. Ending a lease twice does nothing.
    public func endAccess(_ lease: LocalFileLease) async {
        await lease.owner.endAccess(lease)
    }

    /// Runs `body` with a validated local file URL, holding a lease for its duration.
    ///
    /// Throws ``DownloadError/fileUnavailable(_:)`` when no completed file is available.
    public func withLocalFile<T: Sendable>(for id: DownloadID, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        switch try await localFile(for: id) {
        case .unavailable(let reason):
            throw DownloadError.fileUnavailable(reason)
        case .available(let lease):
            do {
                let value = try await body(lease.url)
                await endAccess(lease)
                return value
            } catch {
                await endAccess(lease)
                throw error
            }
        }
    }
}
