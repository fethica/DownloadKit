# DownloadKit

DownloadKit is a durable downloader for finite media files (episodes, tracks, lectures) on iOS: a headless core built on Foundation and Swift concurrency, and an optional SwiftUI layer.

> **Status: contracts and state model only.** The public API, the state machine, the persistence specification and the injectable dependencies are in place and tested. No transfer adapter exists yet: there is no URLSession integration, no SQLite index and no file-system adapter, so the package cannot download anything on its own. Nothing is published; there is no release or tag.

## Products

| Product | Depends on | Purpose |
| --- | --- | --- |
| `DownloadKit` | Foundation | `DownloadManager`, value types, state machine, persistence types, dependency protocols |
| `DownloadKitUI` | `DownloadKit`, SwiftUI | Optional presentation. Currently a single `DownloadListModel` placeholder |

The core imports Foundation only. It never creates a player, never configures an audio session and has no dependency on any playback library; a host resolves a completed file with `localFile(for:)` and plays it however it likes.

## Requirements

- iOS 14.0+ for `DownloadKit`
- iOS 15.0+ for `DownloadKitUI` (availability-gated)
- Swift 6 toolchain; the package builds in Swift 6 language mode with complete concurrency checking

The package also declares macOS 12 so the pure model and state tests run with `swift test` on a Mac. Passing macOS tests say nothing about iOS background transfer behaviour, which needs real-device evidence.

## Installation

Not published. To try it, add the package by local path:

```swift
.package(path: "../DownloadKit")
```

## Quick start

```swift
import DownloadKit

let configuration = try DownloadConfiguration(
    storageScope: StorageScope(namespace: "com.example.player.downloads"),
    sessionIdentifier: "com.example.player.downloads.session",
    dependencies: dependencies          // transport, index store, file system, clock, jitter
)
let manager = DownloadManager(configuration: configuration)
try await manager.start()               // restore and reconcile before any command

let id = try DownloadID("episode-42")
try await manager.enqueue(DownloadRequest(
    id: id,
    url: URL(string: "https://media.example.com/episode-42.m4a")!,
    revision: ContentRevision("2026-10-01"),
    metadata: DownloadMetadata(title: "Episode 42")
))

for await snapshots in await manager.snapshots() {
    // immutable, Sendable values; throttled and bounded
}

if case .available(let lease) = try await manager.localFile(for: id) {
    // play lease.url, then:
    await manager.endAccess(lease)
}
```

Until the production adapters land, `dependencies` must be supplied by the host (the test target shows complete fakes).

## Concepts

### Lifecycle and ownership

- The host creates one `DownloadManager` per storage scope at launch and keeps it. There is no shared instance.
- `start()` resolves the storage root, claims it, loads the index and reconciles it with the transfer session. A second manager for the same root or session identifier in the same process fails with `ownerAlreadyActive`.
- Commands (`enqueue`, `pause`, `resume`, `cancel`, `retry`, `remove`, `setDefaultPolicy`, `setPolicy`) and transfer events are applied one at a time in arrival order. The index is written before in-memory state changes and before any task is started or cancelled.
- `detach()` releases the in-process owner without cancelling transfers. Ending a snapshot subscription or dropping a view never affects transfers.

### Identity and idempotence

Items are identified by a host-supplied `DownloadID`. The source URL can change (for example a refreshed signed link) without changing identity. `ContentRevision`, expected length and checksum define the content: enqueuing the same id with the same content is a no-op, a different content throws `conflictingRequest` and never overwrites a completed file.

### States

`notDownloaded`, `queued`, `active`, `paused(resumable:)`, `waiting(reason)`, `completed(at:)`, `failed(DownloadFailure)`, `removing`, `missing`.

- `progress` is only non-nil when the total size is known; unknown size means indeterminate progress.
- Wait reasons are `networkPolicy`, `connectivity`, `retryScheduled(at:)`, `system` and `unknown`. There is no "waiting for Wi-Fi".
- `missing` means the record exists but the completed file is gone (deleted externally, or not restored from a backup).

### Pause, cancel, remove

- **Pause**: keeps the record and asks the system for resume data. Resume starts a new attempt with it; resume data is best effort.
- **Cancel**: ends the transfer intent and automatic retries. The record and any resume data stay; the item becomes `failed(.cancelled)` and `retry` restarts it.
- **Remove**: cancels, tombstones the record with a new generation so no late event can bring it back, then deletes only that item's own files once every `LocalFileLease` has ended. Group removal takes explicit ids.

### Failures and retries

Failures are classified as network transient, permanent HTTP, authentication, storage, integrity, invalid response, cancelled or policy wait. Only transient failures retry automatically: bounded exponential backoff with jitter, three retries by default, Retry-After honoured. Policy waits spend no attempt. A user retry resets the count and, for an `unauthorized` failure, asks the host's `URLRefreshing` for a fresh URL. Persisted failure keys (`network`, `http`, `storage_full`, `integrity`, ...) are stable.

Retry timers only run while the process runs. The due time is stored, and the next `start()` re-evaluates it.

### Network policy

`NetworkPolicy` is explicit and persisted: `allowsCellular`, `allowsExpensive`, `allowsConstrained` and a scheduling hint. The default, `unmeteredOnly`, refuses cellular and expensive networks and waits while the network is constrained (Low Data Mode). Non-expensive does not prove Wi-Fi, and strict Wi-Fi is not offered because it cannot be enforced for background transfers. Changing the default policy resubmits each queued, active or waiting item exactly once; paused and failed items use it on their next attempt. Path observation is only used to explain waits.

## Storage and persistence

**Storage root.** `Application Support/<namespace>/`, where the namespace is chosen by the host; there is no default namespace and no fallback to Caches or temporary storage. If the root cannot be created, `start()` throws `storageUnavailable`. Inside the root the package owns `staging/` (captured, not yet validated files), `media/` (completed files) and the index. `media/` and `staging/` are excluded from backup; the index is kept, so a restored device reports `missing` items instead of pretending they are complete.

**Relative paths only.** Every path in the index is relative to the root and re-validated when decoded, so a changed sandbox path or a tampered index cannot point outside the root. File names come from internal counters, never from ids, URLs or server-provided names.

**Index record.** One `IndexRecord` per item: id, request identity (source URL, revision, expected length, checksum), metadata, optional policy, phase, attempt generation, automatic retry count and retry time, task binding (session identifier, task identifier, generation), byte counts, HTTP validators, integrity, finalisation journal, staging/final/resume-data paths and timestamps. Generations come from one counter per index and are never reused, so events from an old attempt can never match a removed or re-enqueued item. Headers and credentials are never stored.

**Schema versioning.** `IndexSchema.currentVersion` is 1. A newer stored version fails with `unsupportedSchema` and is left untouched; an unreadable index fails with `corruptIndex` and is preserved. The package never resets an index or deletes unrecognised files to recover.

**Finalisation journal.** `notStarted` → `captured` (temporary file moved into `staging/` before the system callback returns) → `validated` → `renamed` (atomic rename into `media/`) → `committed`. Only a committed record is `completed`. Until validation and atomic rename are implemented, captured files stay captured and are never handed out.

## Concurrency

The manager is a `Sendable` facade over one actor. All mutable state is actor-isolated; dependencies are `Sendable` protocols; snapshots and events are immutable values. The library uses no `@unchecked Sendable`, `nonisolated(unsafe)` or detached tasks, and a test enforces it.

## Testing

```sh
swift test
```

The tests drive the manager with fakes: a scripted transfer session, an in-memory JSON index, an in-memory file system with fault injection, a manual clock and fixed jitter. No test sleeps. They cover every state machine transition, stale-generation rejection, idempotence, ordering, persistence-before-effects, schema refusal, the storage root rule, leases, retries, policy changes and snapshot throttling.

## License

DownloadKit is released under the MIT license. See [LICENSE](LICENSE).
