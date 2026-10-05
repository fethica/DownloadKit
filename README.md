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
- Reconciliation at start maps every system task through the durable description written at submission. A task that matches an item's current attempt is adopted even if its binding was never written; other package tasks, including ones a paused, cancelled or removed item asked to stop, are cancelled again; tasks the package did not create are left alone. A pending stop is enforced only against the exact task it names (same session, item and attempt); if that number is now free or names another task, the stop is acknowledged and the other task is left alone.
- Until reconciliation knows what happened to a restored attempt, a missing binding is not proof that the attempt ended: path and policy changes only change its explanation and never create a replacement. An item whose task is gone is resubmitted only after the session reports that its backlog was delivered (or a background wake's events finished), so a completion buffered before start is applied first. If that report does not arrive within `reconciliationTimeout`, `reconciliationStatus()` returns `unresolved` and nothing is concluded: intent, bytes and generation are kept, and a late marker, a task found by `flushPendingWork()` or the next start resolves it.
- Session events are applied in order and acknowledged to the session only once committed. A completion, failure, retry, binding or removal whose index write is rejected is kept and retried at the start of every later command, or explicitly with `flushPendingWork()`; only progress and waiting updates may be dropped.
- The host forwards a background-session wake to `handleBackgroundEvents(forSession:completionHandler:)`, which returns `false` for other identifiers and may be called before `start()` finishes. The handler is called once, on the main actor, after the manager has applied every event of the wake. If the index cannot take the wake's events within `backgroundWakeBudget`, the handler is called anyway and the events stay unacknowledged with the session, which delivers them again.
- Finalisation runs outside the command chain with a budget (`finalizationBudget`), and a running finaliser is an ownership claim: its destination is recorded with the capture, removal deletes the item's files only after it returned, and `detach()` returns, and frees the root, only after it returned.
- `detach()` releases the in-process owner without cancelling transfers. While a `LocalFileLease` is outstanding the storage claim is kept, so no other manager can take over the root and delete a leased file; a detached manager never deletes files itself. `endAccess(_:)` always ends a lease at the manager that issued it, so a lease that outlived its manager can be ended through the successor. Ending a snapshot iteration in any way, including `break`, unsubscribes; neither it nor dropping a view affects transfers.

### Identity and idempotence

Items are identified by a host-supplied `DownloadID`. The source URL can change (for example a refreshed signed link) without changing identity. `ContentRevision`, expected length and checksum define the content: enqueuing the same id with the same content is a no-op, a different content throws `conflictingRequest` and never overwrites a completed file.

### States

`notDownloaded`, `queued`, `active`, `paused(resumable:)`, `waiting(reason)`, `completed(at:)`, `failed(DownloadFailure)`, `removing`, `missing`.

- `progress` is only non-nil when the total size is known; unknown size means indeterminate progress.
- Wait reasons are `networkPolicy`, `connectivity`, `retryScheduled(at:)`, `system` and `unknown`. There is no "waiting for Wi-Fi".
- `missing` means the record exists but the completed file is gone (deleted externally, or not restored from a backup).

### Pause, cancel, remove

- **Pause**: keeps the record and asks the system for resume data. Resume starts a new attempt with it; resume data is best effort. A new attempt without accepted resume data starts from zero bytes.
- **Cancel**: ends the transfer intent and automatic retries. The record, any resume data and any bytes the attempt already captured stay; the item becomes `failed(.cancelled)` and `retry` restarts it. A cancel (or pause) committed before a running validation's result wins: even a file that was already validated and renamed stays with the cancelled record, and the completion is published only after an explicit `retry` (or `resume`), which validates it again without a new transfer.
- **Remove**: cancels, tombstones the record with a new generation so no late event can bring it back, then deletes only that item's own files once every `LocalFileLease` has ended. Group removal takes explicit ids.
- Each stop keeps the stopped task's binding in the index until the session accepted the cancellation, so a stop interrupted by process exit is enforced again on the next start.
- Captured bytes belong to their attempt: pausing, cancelling, resuming or retrying an item whose download finished but is not yet validated never starts a new transfer over them; resume and retry run the pending validation again. Each attempt accepts one capture: a completion replayed with the same file is a no-op, a replay after the capture was validated or rejected never captures again, and a rejected completion deletes its file only when no record owns it.

### Failures and retries

Failures are classified as network transient, permanent HTTP, authentication, storage, integrity, invalid response, cancelled or policy wait. Only transient failures retry automatically: bounded exponential backoff with jitter, three retries by default. A Retry-After value, capped at `maximumRetryAfter`, can raise the delay but never shorten it. Policy waits spend no attempt. A user retry resets the count and, for an `unauthorized` failure, asks the host's `URLRefreshing` for a fresh URL. Persisted failure keys (`network`, `http`, `storage_full`, `integrity`, ...) are stable.

Retry timers only run while the process runs. The due time is stored, and the next `start()` re-evaluates it.

### Network policy

`NetworkPolicy` is explicit and persisted: `allowsCellular`, `allowsExpensive`, `allowsConstrained` and a scheduling hint. The default, `unmeteredOnly`, refuses cellular and expensive networks and waits while the network is constrained (Low Data Mode). Non-expensive does not prove Wi-Fi, and strict Wi-Fi is not offered because it cannot be enforced for background transfers. Changing the default policy resubmits each queued, active or waiting item exactly once; paused and failed items use it on their next attempt. Path observation is only used to explain waits. One manager owns one session identifier: a per-item scheduling preference is applied per request where the platform allows it and is otherwise a hint; separate sessions per policy are not supported.

## Storage and persistence

**Storage root.** `Application Support/<namespace>/`, where the namespace is chosen by the host; there is no default namespace and no fallback to Caches or temporary storage. If the root cannot be created, `start()` throws `storageUnavailable`. Inside the root the package owns `staging/` (captured, not yet validated files), `media/` (completed files) and the index. `media/` and `staging/` are excluded from backup; the index is kept. At start, and on lookup, a completed item whose file is verifiably absent becomes `missing` instead of pretending to be complete. A file that cannot be inspected (permission, file protection, I/O) is never treated as absent: lookup throws `fileAccessFailed` and the record is kept.

**Relative paths only.** Every path in the index is relative to the root and re-validated when decoded, so a changed sandbox path or a tampered index cannot point outside the root. File names come from internal counters, never from ids, URLs or server-provided names.

**Index record.** One `IndexRecord` per item: id, request identity (source URL, revision, expected length, checksum), metadata, optional policy, phase, attempt generation, automatic retry count and retry time, task binding (session identifier, task identifier, generation), byte counts, HTTP validators, integrity, finalisation journal, staging/final/resume-data paths and timestamps. Generations come from one counter per index and are never reused, so events from an old attempt can never match a removed or re-enqueued item. Records can be rebuilt by external stores through the public `IndexRecord` initialiser, which rejects contradictory fields.

**Credentials.** Headers are never stored, and source URLs with a user or password are rejected (`credentialsInURL`). The source URL is otherwise stored as given, query included. A host whose URLs carry signed query credentials that must stay out of the index enqueues a credential-free URL and returns the signed one from `URLRefreshing.transferURL(for:sourceURL:metadata:)`, which is resolved before every attempt and never persisted. The package never logs URLs.

**Schema versioning.** `IndexSchema.currentVersion` is 1. A newer stored version fails with `unsupportedSchema` and is left untouched; an unreadable index fails with `corruptIndex` and is preserved. The package never resets an index or deletes unrecognised files to recover.

**Finalisation journal.** `notStarted` → `captured` (temporary file moved into `staging/` before the system callback returns, committed with its byte count, validators and planned destination) → `committed`, or `rejected` when validation fails. Between the two, validation, flush and an atomic rename to the deterministic destination `media/item-<generation>` run outside the command chain; they are idempotent, so an interruption anywhere in between is recovered by finalising the same generation again after the next start's replay. Only a committed record is `completed`. Until validation and atomic rename are implemented, captured files stay captured and are never handed out.

**Cleanup intent.** A file the package decides to delete (a stale or rejected capture, a replaced completed file, superseded resume data) is written to the index's `cleanupPaths` in the same commit that releases it, deleted afterwards, and removed from the list only after the deletion was verified. A failed deletion is retried at later commands, `flushPendingWork()` and the next start. Files in `staging/` or `media/` that are neither owned nor listed are unknown: `unreferencedFiles()` reports them and nothing deletes them automatically.

## Concurrency

The manager is a `Sendable` facade over one actor. All mutable state is actor-isolated; dependencies are `Sendable` protocols; snapshots and events are immutable values. The library uses no `@unchecked Sendable`, `nonisolated(unsafe)` or detached tasks. Swift 6 language mode with complete checking is what enforces isolation; a source test additionally trips on those spellings and on non-Foundation imports, as a lexical check only.

## Testing

```sh
swift test
```

The tests drive the manager with fakes: a scripted transfer session, an in-memory JSON index, an in-memory file system with fault injection, a manual clock and fixed jitter. No test sleeps. They cover the command and event transitions exercised in the state machine suites, stale-generation rejection, captured-byte ownership, idempotence, ordering, persistence-before-effects, rejected index writes, restart reconciliation (buffered completions, lost bindings, an initially allowed path, interrupted stops and renames, reused task numbers, a withheld backlog marker), suspended finalisers racing removal, cancel and detach, replay before recovered validation, persisted cleanup intent, schema refusal, the storage root rule, leases across detach, retries, policy changes, background-wake completion and snapshot subscriptions. A separate test target compiles external adapters against the public surface only. They do not cover a real URLSession, SQLite store or file system, which do not exist yet.

## License

DownloadKit is released under the MIT license. See [LICENSE](LICENSE).
