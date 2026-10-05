# DownloadKit

DownloadKit is a durable downloader for finite media files (episodes, tracks, lectures) on iOS: a headless core built on Foundation and Swift concurrency, and an optional SwiftUI layer.

> **Status: foreground downloads.** The public API, the state machine and the production adapters for a foreground session are in place: a URLSession transfer adapter, a SQLite index, a file-system adapter and a validating finaliser. They are tested on macOS with an in-process HTTP fixture. Background transfers, relaunch handling and file protection are not implemented or not proven on iOS yet (see [Integration](#integration)). Nothing is published; there is no release or tag.

## Products

| Product | Depends on | Purpose |
| --- | --- | --- |
| `DownloadKit` | Foundation | `DownloadManager`, value types, state machine, persistence types, dependency protocols |
| `DownloadKitUI` | `DownloadKit`, SwiftUI | Optional presentation. Currently a single `DownloadListModel` placeholder |

The core imports Foundation, plus two system libraries in one file each: SQLite3 for the index store and CryptoKit for checksums. It never creates a player, never configures an audio session and has no dependency on any playback library; a host resolves a completed file with `localFile(for:)` and plays it however it likes.

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
    dependencies: DownloadDependencies(
        transport: URLSessionTransport(),           // foreground session in this version
        makeIndexStore: SQLiteIndexStore.opener(),  // <root>/index.sqlite
        fileSystem: LocalFileSystem()               // Application Support
    )
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

Every dependency is a protocol, so a host can replace any adapter (the test target shows complete fakes).

## Integration

**What the host supplies.**

- A storage namespace and a session identifier. Both are stable for the life of the app: the namespace names the root `Application Support/<namespace>/`, and the identifier names the transfer session.
- The dependencies: `URLSessionTransport()`, `SQLiteIndexStore.opener()` and `LocalFileSystem()` are the production adapters; the clock and jitter default to the system ones. A path source is optional and has no production adapter yet.
- Optionally a `URLRefreshing` implementation, for expired links (`refreshedURL`, persisted) and for per-attempt signed URLs that must stay out of the index (`transferURL`, never persisted).
- One long-lived owner of the `DownloadManager` (for example the app delegate or an app-level model), which calls `start()` at launch.

**What the adapters do.**

- `URLSessionTransport` runs delegate-based download tasks on an ephemeral foreground session. Inside the delegate callback, before it returns, a finished response is checked (status, range continuation, `Content-Length`, media type, HTML bodies) and, when usable, moved into `staging/` with a durable receipt. Terminal events are written to `transfer/` under the root before they are delivered, keep their sequence numbers when replayed, and are deleted once the manager acknowledges them. Redirects are followed except from HTTPS to anything else. Tasks the package did not create are listed and never touched.
- Resume data is opaque. It is used only when it is a property list and the session's network flags (`Options.sessionNetworkAccess`, default `NetworkPolicy.default`) are no more permissive than the item's policy, because a task created from resume data inherits the session's flags. Otherwise the attempt starts from zero. A continuation the server refuses (416) or answers with another representation starts again from zero; a 200 answer to a range request is a complete file, never appended.
- Errors are classified: network loss, timeouts and 408/425/429/5xx are transient (Retry-After parsed from seconds or an HTTP date); a request refused for a cellular, expensive or constrained network is a policy wait; 401/403 are authentication failures; other 4xx are permanent; file errors are storage failures (disk full, permission, protection); certificate failures are permanent.
- `SQLiteIndexStore` writes each change set in one transaction (WAL, full synchronous commits), refuses a newer schema or a foreign or unreadable file without touching it, and coalesces progress-only writes to one per second.
- `LocalFileSystem` confines every path to the base directory, refuses symbolic links below it, separates a verified absence from a failed inspection, renames atomically within a volume and classifies errors.
- The default finaliser validates the evidence recorded with the capture, the file length (against the capture and the host's expected length), the first bytes (no HTML) and the host's SHA-256 in bounded chunks, flushes, renames to `media/item-<generation>[.ext]` and only then lets the manager commit the completion. It defers at its deadline, on cancellation, or when a file is protected; nothing is marked completed before validation.

**Foreground only.** This version creates no background `URLSession`. Transfers run while the app runs. When the process is suspended they stop with it (the system may fail them with a network error, which is retried as transient), and when it ends they end. On the next `start()`, reconciliation finds no task for the attempt and, after the session's backlog marker, starts it again (from zero, or from resume data a pause produced). `handleBackgroundEvents(forSession:completionHandler:)` exists, but nothing calls it in this version because the foreground session never wakes the app.

**Not yet proven on iOS.** Everything above is tested on macOS against an in-process URLProtocol fixture. Not yet shown on an iOS device: background completion and relaunch (not implemented), the effect of file protection on created directories and the classification of protection errors, the interaction of request and session network flags on real cellular, expensive and constrained paths, and system resume data (the fixture cannot produce it, so range continuations are tested at the response-rule level).

## Concepts

### Lifecycle and ownership

- The host creates one `DownloadManager` per storage scope at launch and keeps it. There is no shared instance.
- `start()` resolves the storage root, claims it, loads the index and reconciles it with the transfer session. A second manager for the same root or session identifier in the same process fails with `ownerAlreadyActive`.
- Commands (`enqueue`, `pause`, `resume`, `cancel`, `retry`, `remove`, `setDefaultPolicy`, `setPolicy`) and transfer events are applied one at a time in arrival order. The index is written before in-memory state changes and before any task is started or cancelled.
- Reconciliation at start maps every system task through the durable description written at submission. A task that matches an item's current attempt is adopted even if its binding was never written; other package tasks, including ones a paused, cancelled or removed item asked to stop, are cancelled again; tasks the package did not create are left alone. A pending stop is enforced only against the exact task it names (same session, item and attempt); if that number is now free or names another task, the stop is acknowledged and the other task is left alone.
- Until reconciliation knows what happened to a restored attempt, a missing binding is not proof that the attempt ended: path and policy changes only change its explanation and never create a replacement. An item whose task is gone is resubmitted only after the session reports that its backlog was delivered (or a background wake's events finished), so a completion buffered before start is applied first. If that report does not arrive within `reconciliationTimeout`, `reconciliationStatus()` returns `unresolved` and nothing is concluded: intent, bytes and generation are kept, and a late marker, a task found by `flushPendingWork()` or the next start resolves it.
- Pausing or cancelling an attempt that is not yet confirmed (restored without a binding, or submitted and not yet bound) keeps it stopped, and a later `resume` or `retry` creates no replacement while the old task may still run: the item stays paused or cancelled until its task is found (it is then adopted, or cancelled when no restart was asked for), its completion arrives (it is then validated and kept, never deleted as stale) or its end is proven by the backlog marker or a reported failure (only then does a new attempt start). This also holds after `reconciliationTimeout`.
- Session events are applied in order and acknowledged to the session only once committed. A completion, failure, retry, binding or removal whose index write is rejected is kept and retried at the start of every later command, or explicitly with `flushPendingWork()`; only progress and waiting updates may be dropped.
- The host forwards a background-session wake to `handleBackgroundEvents(forSession:completionHandler:)`, which returns `false` for other identifiers and may be called before `start()` finishes. The handler is called once, on the main actor, after the manager has applied every event of the wake. If the index cannot take the wake's events within `backgroundWakeBudget`, the handler is called anyway and the events stay unacknowledged with the session, which delivers them again. Events are received, and a wake's marker arms the budget, as they arrive, separately from their serial application, so the budget holds even while an index write is suspended; the reconciliation deadline is likewise recorded when it passes, without changing any record.
- Finalisation runs outside the command chain with a budget (`finalizationBudget`), and a running finaliser is an ownership claim: its destination is recorded with the capture, removal deletes the item's files only after it returned, and `detach()` returns, and frees the root, only after it returned. A running finaliser also keeps the root claimed after its manager and every lease were released, so no other manager can start until it returned.
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

**Storage root.** `Application Support/<namespace>/`, where the namespace is chosen by the host; there is no default namespace and no fallback to Caches or temporary storage. If the root cannot be created, `start()` throws `storageUnavailable`. Inside the root the package owns `staging/` (captured, not yet validated files), `media/` (completed files), the index (`index.sqlite` with the production store) and `transfer/` (the transfer adapter's inbox of unacknowledged events). `media/`, `staging/` and `transfer/` are excluded from backup; the index is kept. At start, and on lookup, a completed item whose file is verifiably absent becomes `missing` instead of pretending to be complete. A file that cannot be inspected (permission, file protection, I/O) is never treated as absent: lookup throws `fileAccessFailed` and the record is kept.

**Relative paths only.** Every path in the index is relative to the root and re-validated when decoded, so a changed sandbox path or a tampered index cannot point outside the root. File names come from internal counters, never from ids or server-provided names; a completed file may carry an extension chosen from a fixed allowlist (by declared media type, then by the source URL's extension) so players that infer the format from the name can open it.

**Index record.** One `IndexRecord` per item: id, request identity (source URL, revision, expected length, checksum), metadata, optional policy, phase, attempt generation, automatic retry count and retry time, task binding (session identifier, task identifier, generation), byte counts, HTTP validators, integrity, finalisation journal, staging/final/resume-data paths and timestamps. Generations come from one counter per index and are never reused, so events from an old attempt can never match a removed or re-enqueued item. Records can be rebuilt by external stores through the public `IndexRecord` initialiser, which rejects contradictory fields.

**Credentials.** Headers are never stored, and source URLs with a user or password are rejected (`credentialsInURL`). The source URL is otherwise stored as given, query included. A host whose URLs carry signed query credentials that must stay out of the index enqueues a credential-free URL and returns the signed one from `URLRefreshing.transferURL(for:sourceURL:metadata:)`, which is resolved before every attempt and never persisted. The package never logs URLs.

**Schema versioning.** `IndexSchema.currentVersion` is 1. A newer stored version fails with `unsupportedSchema` and is left untouched; an unreadable index fails with `corruptIndex` and is preserved. The package never resets an index or deletes unrecognised files to recover.

**Finalisation journal.** `notStarted` → `captured` (temporary file moved into `staging/` before the system callback returns, committed with its byte count, validators and planned destination) → `committed`, or `rejected` when validation fails. Between the two, validation, flush and an atomic rename to the deterministic destination `media/item-<generation>[.ext]` run outside the command chain; they are idempotent, so an interruption anywhere in between is recovered by finalising the same generation again after the next start's replay (a file still in staging is validated and renamed; a file already renamed is validated again and committed). Only a committed record is `completed`, and only a committed record is handed out.

**Cleanup intent.** A file the package decides to delete (a stale or rejected capture, a replaced completed file, superseded resume data) is written to the index's `cleanupPaths` in the same commit that releases it, deleted afterwards, and removed from the list only after the deletion was verified. A failed deletion is retried at later commands, `flushPendingWork()` and the next start. Files in `staging/` or `media/` that are neither owned nor listed are unknown: `unreferencedFiles()` reports them and nothing deletes them automatically.

## Concurrency

The manager is a `Sendable` facade over one actor. All mutable state is actor-isolated; dependencies are `Sendable` protocols; snapshots and events are immutable values. The URLSession delegate holds only immutable values: inside each callback it does the synchronous work that cannot wait (judging a finished response, moving its file into `staging/`, writing a receipt) and forwards every callback, in order, through one `AsyncStream` continuation to the session's actor, so arrival order is callback order without a task per callback. The library uses no `@unchecked Sendable`, `nonisolated(unsafe)` or detached tasks. Swift 6 language mode with complete checking is what enforces isolation; a source test additionally trips on those spellings and on imports other than Foundation (outside the one file each for SQLite3 and CryptoKit), as a lexical check only.

## Testing

```sh
swift test
```

The engine tests drive the manager with fakes: a scripted transfer session, an in-memory JSON index, an in-memory file system with fault injection, a manual clock and fixed jitter. None of them sleeps. They cover the command and event transitions exercised in the state machine suites, stale-generation rejection, captured-byte ownership, idempotence, ordering, persistence-before-effects, rejected index writes, restart reconciliation (buffered completions, lost bindings, an initially allowed path, interrupted stops and renames, reused task numbers, a withheld backlog marker), suspended finalisers racing removal, cancel and detach, replay before recovered validation, persisted cleanup intent, schema refusal, the storage root rule, leases across detach, retries, policy changes, background-wake completion and snapshot subscriptions. A separate test target compiles external adapters against the public surface only.

The adapter tests use real files in a temporary directory:

- the SQLite store: round trips of every record shape, schema refusal, foreign and unreadable files, an injected failure inside a transaction, progress coalescing, a copy taken with the connection open and a write torn inside a transaction;
- the file system: absence against failed inspection, path escapes through `..` and symbolic links, chunked reads and hashing, atomic replacement and classified errors;
- the finaliser: every validation failure (nothing renamed), the interrupted rename, deadlines, cancellation and injected full-disk, permission and protection failures;
- the transfer adapter, against a URLProtocol fixture: 200, redirect, missing length, slow first byte, mid-transfer disconnect, truncated body, 404, 500 and 503 with Retry-After, HTML served as success, 401 and 403, an unsolicited 206, 416, unusable resume data, a refused continuation, durable replay with stable sequence numbers and foreign tasks; range continuations are tested at the response-rule level;
- end to end through the manager on the production adapters: completion and offline lookup across a restart, checksum mismatch, error pages, retries, refreshed URLs, a denied write, cancel before the first byte, external deletion, a protected file, a lease across removal, and crash points (after capture, between rename and commit, a committed record whose file is gone, between commit and acknowledgement, an interrupted index write).

The transfer and end-to-end tests wait on URLSession's own threads with bounded real-time polling. They do not cover a background session, a relaunch or an iOS device.

## License

DownloadKit is released under the MIT license. See [LICENSE](LICENSE).
