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
/// 4. ``detach()`` releases the in-process owner without cancelling transfers.
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

    public convenience init(configuration: DownloadConfiguration, urlRefresher: (any URLRefreshing)? = nil) {
        self.init(configuration: configuration, urlRefresher: urlRefresher, finalizer: DeferredFinalizer())
    }

    init(configuration: DownloadConfiguration, urlRefresher: (any URLRefreshing)?, finalizer: any DownloadFinalizing) {
        self.configuration = configuration
        self.engine = DownloadEngine(configuration: configuration, urlRefresher: urlRefresher, finalizer: finalizer)
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

    /// Releases the in-process owner: stops observing events, ends snapshot streams and frees
    /// the storage claim. Transfers already handed to the system are not cancelled.
    public func detach() async {
        await engine.detach()
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
    /// The stream yields the current list immediately, then at most once per
    /// ``DownloadConfiguration/snapshotInterval``. It buffers only the newest list, so a slow
    /// consumer skips intermediate lists instead of growing memory. Ending the iteration
    /// unsubscribes and never affects transfers.
    public func snapshots() async -> AsyncStream<[DownloadSnapshot]> {
        await engine.subscribe()
    }

    // MARK: Local files

    /// Returns a validated completed file and a lease, or why none is available.
    ///
    /// Validation checks the file exists and matches the recorded length. A missing file turns
    /// the item into ``DownloadState/missing``; a size mismatch fails it with
    /// ``DownloadFailure/Kind/integrity``. Nothing is fetched from the network here.
    public func localFile(for id: DownloadID) async throws -> LocalFileResult {
        try await engine.localFile(for: id)
    }

    /// Ends a lease returned by ``localFile(for:)``. A pending removal completes when the last
    /// lease of the item ends.
    public func endAccess(_ lease: LocalFileLease) async {
        await engine.endAccess(lease)
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
