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

### Not yet implemented
- URLSession background transfer adapter, SQLite index store, file-system adapter, path monitor adapter.
- Validation and atomic finalisation, finalisation journal recovery and staging inventory on start.
- Background event forwarding from the app delegate.
