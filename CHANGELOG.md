# Changelog

All notable changes to this project are documented here.

## Unreleased

### Added
- `URLSessionTransport.Mode.background`: a background session under the manager's stable session identifier, with `sessionSendsLaunchEvents`, `isDiscretionary` from `Options.sessionNetworkAccess.scheduling` (user-initiated is non-discretionary), the cellular, expensive and constrained flags from `sessionNetworkAccess`, `waitsForConnectivity` and `Options.resourceTimeout` (`timeoutIntervalForResource`, seven days by default). Background sessions are shared process-wide per identifier. Neither mode keeps a cookie or credential store any more.
- `BackgroundTransferEvents`: the app delegate's receiver for `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, usable before any manager exists. It accepts only the identifiers it was created with and hands each handler to the manager of that identifier, which calls it exactly once on the main actor after the wake's events were committed, or at `backgroundWakeBudget`. `DownloadManager(configuration:urlRefresher:backgroundEvents:)` takes it.
- The adapter turns `urlSessionDidFinishEvents(forBackgroundURLSession:)` into `backgroundEventsFinished`, in order behind every stored event and never ahead of one waiting to be stored; a marker that arrives while no manager reads is delivered to the next one.
- Task descriptions name the session (`downloadkit/2/<session tag>/<generation>/<item>`): `TransferSubmission.taskDescription(sessionIdentifier:)`, `TransferTaskReference.init(taskDescription:taskIdentifier:sessionIdentifier:)` and `SystemTransferTask.reference(inSession:)`. The manager reconciles with the session check, so a task naming another session is foreign and untouched. Format 1 descriptions are still read.
- A refused continuation's restart is recorded under `transfer/<session>/restarts/` inside the callback. After a relaunch the replacement is rebuilt from the system's copy of the request (without range headers) when the submission is unknown, the refused task's late completion is ignored and a cancel of it reaches the replacement, so the restart is no longer reported as a 416 failure.
- `URLSessionTransport`: the production `TransferSessionFactory`, a delegate-based URLSession download adapter. Foreground (ephemeral) session only; `Mode` leaves room for a background configuration. Finished responses are judged and captured into `staging/` inside the delegate callback with a durable receipt; terminal events are stored under `transfer/` before delivery, replayed with their original sequence numbers and deleted on acknowledgement; the backlog marker follows the replay, the task list and every queued callback. Range continuations are validated (200, 206, 416, changed entity tag), resume data is used only when it cannot widen an item's networks, errors and Retry-After are classified, redirects never downgrade from HTTPS, and foreign tasks are left alone.
- `SQLiteIndexStore`: the production `DownloadIndexStore` on the system SQLite library, schema version 1 in its own table, newer schema and foreign or unreadable files refused untouched, one transaction per change set, WAL with full synchronous commits, coalesced progress writes, `opener()`, `flush()` and `close()`.
- `LocalFileSystem`: the production `DownloadFileSystem`, confined to Application Support (or a given base), refusing `..` and symbolic-link escapes, with backup exclusion, file protection on created directories, atomic rename and classified errors (`DownloadFileSystemError`).
- A validating finaliser, used by `DownloadManager(configuration:urlRefresher:)`: response evidence, length, HTML sniffing and the host's SHA-256 in bounded chunks, then flush and atomic rename; repeatable after an interrupted rename; defers at its deadline, on cancellation and for protected files.

### Changed
- `SQLiteIndexStore` takes the write lock before it migrates or creates anything in an existing database and repeats the schema, version and record validation inside that transaction; a newer version or an invalid record committed by another process while the opener waited is refused (typed error, rolled back) instead of migrated, and the journal mode switches to WAL only after the commit.
- The wake budget also starts when a handler is waiting and no marker came (forwarded before start, or after its wake's marker was applied), so a handler is never kept forever by a running manager.
- Index schema version 2 (`IndexSchema.currentVersion`): `IndexRecord` gains `stoppedWhileUnconfirmed`, `restartDeferred` and `policyChangeDeferred` (public initialisers take them as defaulted parameters; older encodings decode them as false). `SQLiteIndexStore` migrates a version 1 index in one transaction; external stores should stamp version 2. A version 1 build refuses a version 2 index.
- A paused or cancelled attempt that was never confirmed stays fenced across a relaunch: an early `resume` or `retry` after the next start creates no replacement, and a buffered completion is captured, never deleted. A restart asked for before the exit is carried out once the old attempt's disposition is known.
- A policy change held for an unconfirmed attempt is enforced when its task is found (by binding, progress, waiting or reconciliation): the task is cancelled and, if a restart was asked for, a new attempt starts under the current policy. A change made while the attempt was stopped is now held too.
- `TransferSessionEvent.Payload` gains `backlogUnavailable` and `ReconciliationUnresolvedReason` gains `sessionStorageFailed`. `URLSessionTransport` delivers a terminal event only after it was stored, keeps a failed event and its receipt and retries them in order with the same sequence number, never treats an unreadable inbox as empty, writes the receipt before it moves a capture, and withholds the backlog marker (sending `backlogUnavailable`) while its storage is incomplete. `flushPendingWork()` reports `reconciliationUnresolved` until the marker arrives.
- The backlog marker is a barrier block on the delegate queue, so it cannot overtake an older queued callback.
- A 206 continuation must start at the requested offset and carry a confirmed `If-Range` validator (a strong `ETag` or an equal `Last-Modified`); otherwise it restarts from zero.
- `URLError.dataNotAllowed` is a policy wait and `URLError.noPermissionsToReadFile` a permission storage failure.
- `DownloadFileSystem` gains `synchronizeDirectory(at:)` (default: does nothing) and `DownloadFileSystemError.Kind` gains `directoryFlushFailed`. `LocalFileSystem.moveItem` flushes both directories and reports a failed flush; the finaliser defers and flushes again before reporting a renamed file finalised.
- Transfer inbox, capture, resume data and the SQLite database go through one root-confinement rule (`PathConfinement`): a symbolic link in their path is refused.
- `SQLiteIndexStore` validates an existing index read-only before opening it for writing; a populated index without its counter, with contradictory records or with a generation not below its counter is refused as `corruptIndex` and left byte for byte unchanged.
- A replaced or discarded file stays on disk while a lease on it is outstanding; its deletion intent stays persisted and runs when the lease ends.
- `resume` and `retry` of a paused or cancelled attempt that is not yet confirmed create no replacement. The item stays stopped until the old task is found (adopted for the restart, or cancelled when none was asked for), its completion arrives (validated and kept, never deleted as stale) or its end is proven by the backlog marker or a reported failure. This holds after `reconciliationTimeout` too.
- Session events are received, and a wake's marker arms `backgroundWakeBudget`, outside the serial application of events; `reconciliationTimeout` records the unresolved status outside it as well. Both now hold while an index write is suspended; uncommitted events stay unacknowledged and the storage claim is kept while the write is outstanding.
- A running finaliser holds its manager's engine, and with it the storage claim, until it returned, also after the manager and every lease were released. Port signatures are unchanged.
- `ResponseValidators` gains `statusCode` and `mediaType` (optional, decoded as absent from older data).
- A completed file may be named `media/item-<generation>.<ext>`, with the extension chosen from an allowlist by declared media type, then by the source URL's extension.
- `DownloadManager(configuration:urlRefresher:)` now validates and finalises captured files instead of leaving them captured.

### Added
- `DownloadKit` core library (Foundation only, iOS 14+) and optional `DownloadKitUI` library (iOS 15+).
- `DownloadManager`: host-owned, explicit configuration, `start()` before commands, single owner per storage root and session identifier, serialised commands (`enqueue`, `pause`, `resume`, `cancel`, `retry`, `remove`, `setDefaultPolicy`, `setPolicy`), throttled and bounded snapshot stream, `localFile(for:)` with read leases.
- Value types: `DownloadID`, `ContentRevision`, `ContentChecksum`, `DownloadRequest`, `DownloadMetadata`, `DownloadState`, `WaitReason`, `DownloadSnapshot`, `DownloadFailure`, `FailureClass`, `TransferFailure`, `DownloadError`, `NetworkPolicy`, `RetryPolicy`, `LocalFileLease`, `LocalFileResult`.
- Pure state machine with generation counters, idempotent enqueue, conflict detection and bounded retries.
- Persistence specification: `IndexRecord`, `IndexContents`, `IndexChangeSet`, `FinalizationJournal`, `RelativePath`, `StorageScope`, schema version 1 with refusal of newer versions.
- Dependency protocols: `TransferSessionFactory`, `TransferSession`, `DownloadIndexStore`, `DownloadFileSystem`, `DownloadClock`, `RetryJitter`, `NetworkPathSource`, `URLRefreshing`; `SystemClock` and `SystemJitter`.

### Changed
- `DownloadFileSystem.fileSize(at:)` is replaced by `inspectItem(at:) throws -> FileStatus`, which separates a verified absence from a failed inspection. The port also gains `contentsOfDirectory(at:)`, `readBytes(at:offset:maximumLength:)` and `synchronizeFile(at:)`.
- `TransferSession.events` now carries `TransferSessionEvent` values: a sequence number and a payload that is a task event, `backlogDelivered` or `backgroundEventsFinished`. Sessions must not drop terminal events and must deliver unacknowledged ones again after reconnection.
- `TransferSession.activeTasks()` is replaced by `systemTasks() -> [SystemTransferTask]`, which includes tasks the package cannot map; `acknowledge(through:)` is new; `cancel` returning is the acknowledgement of a stop.
- `DownloadManager.snapshots()` returns `DownloadSnapshotStream`; each iteration is one subscription and ends on `break`, cancellation or release.
- `DownloadManager.detach()` keeps the storage claim while leases are outstanding, and a lease keeps its manager's claim alive. `LocalFileLease` equality ignores the owner.
- `FinalizationJournal` drops the unreachable `validated` and `renamed` cases; captured records are finalised again at start for the same generation.
- `RetryPolicy.delay(forRetry:jitter:retryAfter:)`: a capped Retry-After can raise the delay but no longer shortens it.
- Enqueue and source updates reject URLs with a user or password.
- `IndexRecord` gains `finalizationDestination`, written with the capture and owned until the completion commits; `ownedPaths` includes it. The public initialiser takes it as an optional parameter.
- `FinalizationJournal` gains `rejected`: the attempt's capture was consumed by a failed validation, and a replay never captures again. Every new attempt resets the journal to `notStarted`.
- `IndexContents` gains `cleanupPaths` and `IndexChangeSet` gains `cleanupQueued` and `cleanupCompleted`; external stores must persist them. Older encoded contents without the field decode with an empty list.
- `DownloadConfiguration.init` gains `reconciliationTimeout`, `backgroundWakeBudget` and `finalizationBudget` (defaulted).
- `DownloadManager.endAccess(_:)` ends the lease at the manager that issued it, and ending a lease twice does nothing.
- `DownloadManager.detach()` returns only after running finalisers returned, and frees the storage root only then.
- A finalisation result no longer publishes a completion for an item paused or cancelled while it ran; the validated file stays with the record until `resume` or `retry`.
- `TransferSession` contract: a redelivered event keeps its sequence number across session objects and relaunches; `backlogDelivered` is specified as a fence over the adapter's durable inbox and queued system callbacks.

### Added
- `DownloadManager.handleBackgroundEvents(forSession:completionHandler:)` and `flushPendingWork()`.
- `FileStatus`, `TransferSessionEvent`, `SystemTransferTask`, `DownloadSnapshotStream`.
- `TransferSubmission.taskDescription` and `TransferTaskReference.init?(taskDescription:taskIdentifier:)`.
- `URLRefreshing.transferURL(for:sourceURL:metadata:)`, defaulting to the stored URL.
- `IndexRecord.stoppingBinding`; public initialisers for `IndexRecord` (validating), `RequestIdentity` and `TaskBinding`.
- `DownloadError.credentialsInURL`, `fileAccessFailed`, `invalidStoredRecord`, `reconciliationUnresolved`; `TransferFailure.credentialsUnavailable`.
- `DownloadManager.reconciliationStatus()` with `ReconciliationStatus` and `ReconciliationUnresolvedReason`.
- `DownloadManager.unreferencedFiles()`, which reports unknown files in `staging/` and `media/` without deleting them.

### Fixed
- Start-up no longer replaces an attempt whose completion was buffered before start, and adopts a task whose binding was never written instead of creating a duplicate.
- A completion arriving after cancel, or replayed with the same file, no longer deletes bytes the record owns.
- An inspection failure no longer turns a completed item into `missing`.
- Terminal events, retry firings, bindings and removals whose index write is rejected are kept and retried instead of being lost.
- Captured bytes no longer block later attempts after pause, resume, cancel or retry; fresh attempts reset byte counts and validators.
- Pause, cancel and remove keep the stopped task's binding until the cancellation is acknowledged, and reconciliation enforces it after a restart.
- Breaking out of a snapshot loop over a retained stream now unsubscribes.
- A path or policy update during start-up reconciliation no longer creates a replacement attempt over a task that may still exist or a completion that is still buffered.
- A finaliser can no longer leave a media file behind after its item was removed, or write to the storage root after a detach handed it to another manager.
- A lease that outlived its released manager can be ended through the successor, which can then start.
- A replayed completion can no longer revive a capture that a recovered validation already rejected and deleted; recovered validation waits for the start-up replay.
- A pending stop no longer cancels an unrelated or foreign task that reuses the stopped task's number.
- A missing backlog marker or an index that keeps rejecting writes no longer blocks reconciliation or a background-wake handler indefinitely.
- Failed file deletions are no longer forgotten: their intent is persisted and retried until verified.

### Not yet implemented
- A background URLSession configuration, the relaunch path and its exactly-once wake coordination with the transfer adapter.
- A path monitor adapter.
- Verification on an iOS device (background completion, file protection, network flags, system resume data).
