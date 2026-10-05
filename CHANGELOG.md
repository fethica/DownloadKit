# Changelog

All notable changes to this project are documented here.

## Unreleased

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

### Added
- `DownloadManager.handleBackgroundEvents(forSession:completionHandler:)` and `flushPendingWork()`.
- `FileStatus`, `TransferSessionEvent`, `SystemTransferTask`, `DownloadSnapshotStream`.
- `TransferSubmission.taskDescription` and `TransferTaskReference.init?(taskDescription:taskIdentifier:)`.
- `URLRefreshing.transferURL(for:sourceURL:metadata:)`, defaulting to the stored URL.
- `IndexRecord.stoppingBinding`; public initialisers for `IndexRecord` (validating), `RequestIdentity` and `TaskBinding`.
- `DownloadError.credentialsInURL`, `fileAccessFailed`, `invalidStoredRecord`; `TransferFailure.credentialsUnavailable`.

### Fixed
- Start-up no longer replaces an attempt whose completion was buffered before start, and adopts a task whose binding was never written instead of creating a duplicate.
- A completion arriving after cancel, or replayed with the same file, no longer deletes bytes the record owns.
- An inspection failure no longer turns a completed item into `missing`.
- Terminal events, retry firings, bindings and removals whose index write is rejected are kept and retried instead of being lost.
- Captured bytes no longer block later attempts after pause, resume, cancel or retry; fresh attempts reset byte counts and validators.
- Pause, cancel and remove keep the stopped task's binding until the cancellation is acknowledged, and reconciliation enforces it after a restart.
- Breaking out of a snapshot loop over a retained stream now unsubscribes.

### Not yet implemented
- URLSession background transfer adapter, SQLite index store, file-system adapter, path monitor adapter.
- Validation and atomic finalisation (the default finaliser defers), and an inventory of unreferenced files in `staging/` and `media/` on start.
- A durable on-disk inbox for session events; the manager keeps rejected events in memory and relies on the session redelivering unacknowledged ones after a relaunch.
