# DownloadKit

DownloadKit is a durable downloader for finite media files (episodes, tracks, lectures) on iOS: a headless core built on Foundation and Swift concurrency, and an optional SwiftUI layer.

> **Status: foreground and background sessions, not yet proven on a device.** The public API, the state machine and the production adapters are in place: a URLSession transfer adapter with a foreground and a background mode, a relaunch receiver for the app delegate, a SQLite index, a file-system adapter and a validating finaliser. They are tested on macOS with an in-process HTTP fixture and scripted relaunches. A background session's real transfers, wakes and relaunches, and file protection, are not proven on iOS hardware yet (see [Platform limits](#platform-limits)). Nothing is published; there is no release or tag.

## Products

| Product | Depends on | Purpose |
| --- | --- | --- |
| `DownloadKit` | Foundation | `DownloadManager`, value types, state machine, persistence types, dependency protocols |
| `DownloadKitUI` | `DownloadKit`, SwiftUI | Optional presentation: a list model, download controls, a downloads list, a network policy picker and a status banner (see [SwiftUI](#swiftui)) |

Neither product depends on a player: `DownloadKitUI` imports SwiftUI, Foundation and the core only, and the core does not import SwiftUI. The [sample app](#sample-app) adds playback at the app level.

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
        transport: URLSessionTransport(options: .init(mode: .background)),
        makeIndexStore: SQLiteIndexStore.opener(),  // <root>/index.sqlite
        fileSystem: LocalFileSystem()               // Application Support
    )
)
let manager = DownloadManager(configuration: configuration, backgroundEvents: wakes) // see below
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

### App delegate wiring

A background session needs the app delegate: when transfers finish while the app is suspended or was terminated by the system, the system relaunches the app in the background and calls `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. `BackgroundTransferEvents` accepts that call from the first moment of the process, before any manager exists, and hands the completion handler to the manager of that session identifier.

```swift
import UIKit
import DownloadKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let sessionIdentifier = "com.example.player.downloads.session"
    let wakes = BackgroundTransferEvents(sessionIdentifiers: [AppDelegate.sessionIdentifier])
    private(set) var downloads: DownloadManager?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Create and start the manager at every launch, background relaunches included:
        // starting it recreates the session under the same identifier, which is what lets
        // the system deliver the finished transfers.
        let manager = DownloadManager(configuration: makeConfiguration(), backgroundEvents: wakes)
        downloads = manager
        Task { try await manager.start() }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if !wakes.handleEvents(forSession: identifier, completionHandler: completionHandler) {
            completionHandler() // another library's session: answer for it, or forward it there
        }
    }
}
```

With SwiftUI, put the same delegate behind `@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate` and read `appDelegate.downloads` from the app; the adaptor's delegate exists before the first scene, so the order is the same.

What the receiver guarantees: only the identifiers it was created with are accepted (any other returns `false` and is not kept); a handler that arrives before the manager exists, before `start()` or after it is kept; each handler, including a duplicate forward, is called exactly once, on the main actor, after the manager has applied and committed every event of the wake up to the session's wake-drained marker (the capture moved into `staging/`, its event stored in `transfer/`, the index committed). If that cannot happen within `backgroundWakeBudget` (counted from the first unanswered handler or marker the running manager saw), the handlers are called anyway and the uncommitted events stay unacknowledged with the session, which delivers them again. A manager that was never created or started never calls a handler. A manager created without a receiver still accepts handlers through `handleBackgroundEvents(forSession:completionHandler:)`.

## Integration

**What the host supplies.**

- A storage namespace and a session identifier. Both are stable for the life of the app: the namespace names the root `Application Support/<namespace>/`, and the identifier names the transfer session.
- The dependencies: `URLSessionTransport()` (foreground) or `URLSessionTransport(options: .init(mode: .background))`, `SQLiteIndexStore.opener()` and `LocalFileSystem()` are the production adapters; the clock and jitter default to the system ones. A path source is optional and has no production adapter yet.
- Optionally a `URLRefreshing` implementation, for expired links (`refreshedURL`, persisted) and for per-attempt signed URLs that must stay out of the index (`transferURL`, never persisted).
- One long-lived owner of the `DownloadManager` (for example the app delegate or an app-level model), which calls `start()` at every launch, and, for a background session, the app delegate forwarding described in [App delegate wiring](#app-delegate-wiring).

**What the adapters do.**

- `URLSessionTransport` runs delegate-based download tasks on a foreground or a background session (see the modes below). Inside the delegate callback, before it returns, a finished response is checked (status, range continuation, `Content-Length`, media type, HTML bodies) and, when usable, a durable receipt naming its staging file is written and only then is the file moved into `staging/`; if the receipt cannot be written nothing is moved and the attempt fails as a storage failure. Terminal events are written to `transfer/` under the root before they are delivered, keep their sequence numbers when replayed, and are deleted once the manager acknowledges them. A terminal event that cannot be written (or whose sequence number cannot be reserved) is kept with its receipt and retried in order, and nothing after it is delivered meanwhile; an inbox that cannot be read is never treated as empty. In both cases the backlog marker is withheld and the session reports `backlogUnavailable`, so reconciliation stays unresolved (`sessionStorageFailed`) until storage recovers. The marker itself is a barrier on the delegate queue, behind every callback queued before it. Redirects are followed except from HTTPS to anything else. Tasks the package did not create are listed and never touched. Every file the adapter opens, creates or deletes is checked against the root: a symbolic link in its path is refused.
- Resume data is opaque. It is used only when it is a property list and the session's network flags (`Options.sessionNetworkAccess`, default `NetworkPolicy.default`) are no more permissive than the item's policy, because a task created from resume data inherits the session's flags. Otherwise the attempt starts from zero. A 206 continuation is accepted only when it starts exactly at the kept offset, runs to the last byte, the assembled file has the full length, and the `If-Range` validator sent is confirmed by the response (a strong `ETag` equal to it, or a `Last-Modified` equal to its date); a missing or weak validator, another offset or a changed representation starts again from zero, as does a refused continuation (416). A 200 answer to a range request is a complete file, never appended. Resume data is stored as the opaque blob the system produced; whether it embeds request details is not established, so a host with secret-bearing transfer URLs should treat it like the request itself.
- Errors are classified: network loss, timeouts and 408/425/429/5xx are transient (Retry-After parsed from seconds or an HTTP date); a request refused for a cellular, expensive or constrained network (including a disallowed cellular data connection) is a policy wait and spends no retry; 401/403 are authentication failures; other 4xx are permanent; file errors, including a file the process may not read, are storage failures (disk full, permission, protection); certificate failures are permanent.
- `SQLiteIndexStore` writes each change set in one transaction (WAL, full synchronous commits) and coalesces progress-only writes to one per second. An existing index is first validated on a read-only connection in one read transaction (version, tables, required globals, every record through the validating initialiser, generations below the stored counter); a newer schema, a foreign or unreadable file, or a populated index that fails any check is refused with nothing written, not even a journal mode change. Only an empty database is treated as never written. The writable connection then takes the write lock first and repeats every check inside that transaction, so an index another process changed in between (a newer version, an invalid record) is refused rather than migrated; a valid version 1 index is migrated to version 2 in that transaction, and only after it commits does the journal mode switch to WAL. The database and its companion files must not be symbolic links.
- `LocalFileSystem` confines every path to the base directory, refuses symbolic links below it, separates a verified absence from a failed inspection, renames atomically within a volume and classifies errors. After a rename it flushes the destination and source directories; a failed flush is reported (`directoryFlushFailed`), and the finaliser then keeps the renamed file, defers, and flushes again before it reports the file finalised.
- The default finaliser validates the evidence recorded with the capture, the file length (against the capture and the host's expected length), the first bytes (no HTML) and the host's SHA-256 in bounded chunks, flushes, renames to `media/item-<generation>[.ext]` and only then lets the manager commit the completion. It defers at its deadline, on cancellation, or when a file is protected; nothing is marked completed before validation.

**Two session modes.** `URLSessionTransport(options: .init(mode: .foreground))` (the default) runs an ephemeral session in the process: transfers stop when the process is suspended or ends, and the next `start()` reconciles and starts them again. `.background` runs a background session under the manager's session identifier:

- `URLSessionConfiguration.background(withIdentifier:)` with the stable identifier and `sessionSendsLaunchEvents`.
- `isDiscretionary` follows `Options.sessionNetworkAccess.scheduling`: `userInitiated` (the default, for downloads a person asked for) is non-discretionary; `deferred` lets the system postpone every task of that session, for example until the device charges on Wi-Fi. Discretion is per session, so a deferred item in a non-discretionary session only gets the background network service type on its request.
- `allowsCellularAccess`, `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` come from `sessionNetworkAccess`, and each request narrows them with its item's policy. `waitsForConnectivity` is on, `timeoutIntervalForResource` is `Options.resourceTimeout` (seven days by default), and there is no URL cache, cookie store or credential store.
- A background session is process-wide: every background transport in a process shares one session object and one delegate per identifier (the system allows only one), kept for the life of the process, so a manager created after a `detach()` reconnects to the same session.
- Everything listed above for the adapter holds in both modes: capture inside the callback, the durable inbox before delivery, the barrier before the backlog marker, the root confinement. The system's `urlSessionDidFinishEvents(forBackgroundURLSession:)` becomes the wake-drained marker, queued behind every event before it and never ahead of one still waiting to be stored; a marker that arrives while no manager reads is delivered to the next one.
- Each task's description names its item, attempt and session (`downloadkit/2/<session tag>/<generation>/<item>`, the tag being a hash of the identifier). On start the manager lists the session's tasks: a task of the current attempt is adopted, the package's other tasks are cancelled, and tasks without a package description or naming another session are listed and never touched. Descriptions written without a session (`downloadkit/1/...`) are still read.
- A refused continuation (416, or a range answer that cannot be trusted) is recorded under `transfer/` inside the callback and restarted from zero under the same attempt, from the submission or, after a relaunch, from the system's copy of the request without its range headers. After a relaunch the record lets the session ignore the refused task's late completion and route a cancel to its replacement, so a restart never turns into a failure.

## Platform limits

What the system does with a background session, and what the package does in each case. The package's behaviour is tested as described below; the system's behaviour is the platform's documented contract and is not yet confirmed on hardware for this package.

- **Normal suspension.** The app is suspended; the system keeps transferring. When tasks finish it wakes or relaunches the app in the background, the session's events are delivered, and the receiver's handler is called once they are committed (or at the wake budget). Progress is not reported while the app is suspended.
- **System termination** (memory pressure, a crash, the system ending a background launch). Transfers continue in the system. The next background relaunch, or the next launch, recreates the session under the same identifier when the host starts the manager; reconciliation adopts the surviving tasks by description, the session replays its durable inbox with the original sequence numbers, and only then, after the backlog marker, is an attempt whose task is gone started again.
- **User force-quit** (swiping the app away). The system cancels the session's transfers and does not relaunch the app for them; nothing continues until the user opens the app again. The package promises no automatic continuation and runs no timer while the app is absent.
- **Reboot.** In-flight background tasks may not survive a reboot, and files created with complete file protection cannot be read until the device is unlocked. On the next launch the manager reconciles: an attempt without a task is started again after the backlog marker, a completed file that cannot be inspected is reported as `fileAccessFailed`, never as missing.
- **A later foreground launch.** Reconcile, then honest state: adopted tasks report progress again, buffered completions are validated before anything is resubmitted, retries whose time passed are fired, and what cannot be decided within `reconciliationTimeout` is reported as `unresolved` instead of guessed.
- **The wake budget.** A background wake gives the app a short time. `backgroundWakeBudget` (20 seconds by default) bounds how long a handler waits: at the budget it is called even if the index could not commit the wake's events; those events stay in the session's inbox, their captures stay in `staging/`, and they are applied on a later wake or launch. Validation (hashing) runs under its own `finalizationBudget` and defers rather than holding the handler.
- **Retry timers** only run while the process runs; the due time is persisted and re-evaluated at the next start. A scheduled retry never wakes the app.

What the tests prove and what they do not. The macOS tests prove the package's side: the configuration each mode builds, task descriptions and their session check, the order of the wake marker against stored events, restart records across a relaunch, the receiver's exactly-once handling (before the manager exists, before and after start, duplicates, unrelated identifiers, markers before and after the budget, events buffered before start, the main thread), and repair of every interruption window between intent, task, capture, rename and index commit. They do not run a background transfer: a background session's transfers run in a system process that URLProtocol stubs cannot reach, and macOS does not reproduce iOS suspension, relaunch, force-quit, reboot or file protection. Only hardware can show those, together with the effect of file protection on the created directories and the classification of protection errors, the interaction of request and session network flags on real cellular, expensive and constrained paths, discretionary scheduling under energy restrictions, and system resume data (the fixture cannot produce it, so range continuations are tested at the response-rule level).

## SwiftUI

`DownloadKitUI` is optional and iOS 15+ (availability-gated). It presents a manager the host owns; nothing in it starts, detaches or releases the manager, so leaving a screen never affects transfers.

```swift
import DownloadKitUI

struct DownloadsScreen: View {
    @StateObject private var downloads: DownloadListModel

    init(manager: DownloadManager) {
        _downloads = StateObject(wrappedValue: DownloadListModel(controller: manager))
    }

    var body: some View {
        DownloadList(model: downloads)
            .task { await downloads.observe() }   // one subscription while visible
    }
}
```

**What it offers.**

- `DownloadListModel`: a main-actor `ObservableObject` over the snapshot stream. `observe()` is one subscription that ends when its task is cancelled (SwiftUI cancels `.task` when the view disappears) or the stream ends. It publishes `items` only when the presentation changed: progress is rounded to 1% and byte counts to 64 KiB (both configurable), on top of the stream's own throttling. Commands (`perform(_:on:)`) ignore a second tap while one is in flight for the same item; removal asks for confirmation first (`requestRemoval(of:title:)`, `confirmRemoval()`) and always passes explicit identifiers. `openLocalFile(for:)` returns a lease that the host ends with `endAccess(_:)` or `endAllAccess()`; it is not ended when a view disappears, because playback may outlive the view, and it never fetches. Failures keep only a reason (`DownloadCommandFailure.Reason`), never identifiers, paths or URLs.
- `DownloadButton`: one control per item that shows its state (not downloaded, queued, downloading with progress or indeterminate, waiting with its reason, paused, failed with its kind, downloaded, removing, missing) and performs the state's primary action on tap: download (through a closure, because only the host can build the request), pause, resume or retry. Every action, removal included, is in its context menu.
- `DownloadList`: the banner, one section per metadata group (with a confirmed "Remove All" that removes the group's members), a row per item with swipe, context-menu and VoiceOver actions, and the removal and failure dialogs.
- `NetworkPolicyPicker`: the default policy among unmetered networks, unmetered including Low Data Mode, and any network. A custom policy set by the host is shown as such and is not overwritten until the person picks one. There is no Wi-Fi option, because the package cannot prove a network is Wi-Fi.
- `ReconciliationBanner`: restoring, unconfirmed items (`unresolved`), unreadable transfer storage (`sessionStorageFailed`) and a start failure the host reports with `reportStartFailure(_:)`.
- `DownloadControlling`: the protocol the model talks to. `DownloadManager` conforms; a host can wrap it, and tests use a fake.
- `DiagnosticRedaction.redact(_:)`: removes URLs and absolute paths from text before a host displays it, for example in a diagnostics screen.

**Strings and theming.** Every string comes from the package's English `Localizable.strings`. A host overrides any key by adding a `DownloadKitUI.strings` table to its app bundle (localised as usual), or by setting `.environment(\.downloadStrings, DownloadStrings { key in ... })` for a lookup of its own; the keys are listed in `DownloadStringKey`. The controls use system fonts, `accentColor`, semantic colors and SF Symbols, so `.tint`, `.font` and the color scheme theme them; for a different layout, build views on `DownloadListModel` and `DownloadIndicator` directly.

**Accessibility.** The status indicator is one element labelled "Download status" whose value is the full status ("Downloading, 42%", "Waiting for an allowed network", "Failed: not enough storage"); every state has its own symbol, so color is never the only cue. Buttons are labelled with the action and the item ("Pause Tone A") and carry a hint. A row is one VoiceOver element read as title, subtitle, then status, with its actions in the actions rotor instead of separate stops. Sizes follow Dynamic Type (`@ScaledMetric`, text styles, no fixed widths); at accessibility sizes the row drops the indicator and shows the action as text so nothing is truncated. Layouts use leading and trailing alignment and the progress ring is mirrored in right-to-left languages. These were checked in code and in the model tests, not with VoiceOver on a device.

## Sample app

`sample/` holds a small iOS app that consumes the package like any other app, through its public API only, and a fixture server for it.

```sh
cd sample
xcodegen generate                      # creates DownloadKitSample.xcodeproj (not committed)
open DownloadKitSample.xcodeproj

cd fixture-server                      # in another terminal, on the Mac
swift run -c release fixture-server    # serves on 0.0.0.0:8080 and prints the Mac's LAN address
```

In the simulator the app reaches the server on `127.0.0.1:8080`; on a device, enter the Mac's address in the Developer tab. The app's Info.plist allows plain HTTP to local hosts only (`NSAllowsLocalNetworking`) and asks for local network access; the package itself relaxes nothing.

**The app.** A SwiftUI app whose `@UIApplicationDelegateAdaptor` delegate creates a `BackgroundTransferEvents` and one `DownloadManager` at every launch (background session, `Application Support/sample/`, unmetered default policy), starts it, and forwards `handleEventsForBackgroundURLSession`. Four tabs:

- **Fixtures**: every fixture with a `DownloadButton` (enqueue, progress, pause, resume, retry; long press for cancel and remove), the network policy picker and the banner. Items carry the server's recorded SHA-256, so a changed byte fails validation.
- **Downloads**: the ready-made `DownloadList`, grouped by Tones, Large files and Scenarios.
- **Play**: completed-only local playback through FRadioPlayer, an optional dependency of the sample only (`from: 0.4.0` in `project.yml`; remove it and the screen explains what is missing). The file is resolved through a lease and the lease ends when playback stops. With "Offline only" on, an item without a validated local file is reported and nothing is fetched; with it off, the app streams the server's copy after saying why the local file was not used. Artwork lookups are turned off.
- **Developer**: the server address, scenario switches sent to the server's control endpoint, the manager's reconciliation status, waiting wake handlers, unreferenced files, "Flush pending work", the session's network setting (applied at the next launch), a debug-only "Exit now" to end the process mid-transfer, and an event log. The log is kept across launches, so a background relaunch can be read afterwards, and every entry goes through `DiagnosticRedaction`.

**The fixture server** is a separate Swift package in `sample/fixture-server` (Foundation only, macOS 13+, `swift build` and `swift test` there); it is not part of the library products. It generates its files at start-up from fixed parameters (documented in `Fixtures.swift`): three 3-second tones and a 60-second tone as 16-bit mono WAV at 22,050 Hz, and a 24 MiB pseudo-random file, and checks them against the recorded SHA-256 values the app uses. `--write DIR` writes them and a `manifest.json` instead of serving. Routes:

| Route | Response |
| --- | --- |
| `/files/<name>` | 200, single ranges answered with 206 (`If-Range` honoured), or the scenario set for the file |
| `/s/<scenario>/<name>` | the named scenario |
| `/control/set?file=<name>&scenario=<s>[&times=<n>]` | serve `<name>` with `<s>` for the next `n` requests, or until cleared (GET or POST) |
| `/control/clear[?file=<name>]`, `/control/state`, `/control/scenarios` | clear, inspect and list |
| `/manifest.json` | names, lengths, digests, generator parameters |

Scenarios: `ok`, `ignore-range` (200 to a range request), `range-416`, `changing-etag` (a new validator on every response), `redirect`, `no-length`, `slow-first-byte` (8 s), `slow-body` (64 KiB/s), `disconnect` (reset after 40%), `truncated` (1 KiB short, clean close), `not-found`, `server-error` (500, Retry-After 3), `unavailable` (503, Retry-After 10), `html`, `html-as-media` (an HTML page declared as audio), `checksum-mismatch` (one byte changed), `expired` (403; the app's `URLRefreshing` returns the plain file on retry) and `unauthorized` (401). Normal responses are sent at 1 MiB/s by default (`--rate`), so progress and pause are visible.

**What the sample proves, and what it does not.** It compiles as an independent consumer of both products and the optional player against the public API, and its wiring is the one documented above. It has not been run on hardware: background completion, relaunch after "Exit now", force-quit, reboot, network transitions and audible playback are all still to be observed on a device, using the event log as evidence. The simulator does not reproduce a device's suspension or relaunch behaviour.

## Concepts

### Lifecycle and ownership

- The host creates one `DownloadManager` per storage scope at launch and keeps it. There is no shared instance.
- `start()` resolves the storage root, claims it, loads the index and reconciles it with the transfer session. A second manager for the same root or session identifier in the same process fails with `ownerAlreadyActive`.
- Commands (`enqueue`, `pause`, `resume`, `cancel`, `retry`, `remove`, `setDefaultPolicy`, `setPolicy`) and transfer events are applied one at a time in arrival order. The index is written before in-memory state changes and before any task is started or cancelled.
- Reconciliation at start maps every system task through the durable description written at submission. A task that matches an item's current attempt is adopted even if its binding was never written; other package tasks, including ones a paused, cancelled or removed item asked to stop, are cancelled again; tasks the package did not create are left alone. A pending stop is enforced only against the exact task it names (same session, item and attempt); if that number is now free or names another task, the stop is acknowledged and the other task is left alone.
- Until reconciliation knows what happened to a restored attempt, a missing binding is not proof that the attempt ended: path and policy changes only change its explanation and never create a replacement. An item whose task is gone is resubmitted only after the session reports that its backlog was delivered (or a background wake's events finished), so a completion buffered before start is applied first. If that report does not arrive within `reconciliationTimeout`, `reconciliationStatus()` returns `unresolved` and nothing is concluded: intent, bytes and generation are kept, and a late marker, a task found by `flushPendingWork()` or the next start resolves it.
- Pausing or cancelling an attempt that is not yet confirmed (restored without a binding, or submitted and not yet bound) keeps it stopped, and a later `resume` or `retry` creates no replacement while the old task may still run: the item stays paused or cancelled until its task is found (it is then adopted, or cancelled when no restart was asked for), its completion arrives (it is then validated and kept, never deleted as stale) or its end is proven by the backlog marker or a reported failure (only then does a new attempt start). This also holds after `reconciliationTimeout`, and across a relaunch: the unconfirmed stop, a deferred restart and a held policy change are persisted with the record (schema version 2), so the next start fences the stopped attempt like an awaiting one.
- A policy change for an unconfirmed attempt, stopped or not, is held until its task is known. A found task was created under the old policy and is never adopted under the new one: it is cancelled and, when a restart was asked for, a new attempt starts under the current policy. The change is consumed once.
- Session events are applied in order and acknowledged to the session only once committed. A completion, failure, retry, binding or removal whose index write is rejected is kept and retried at the start of every later command, or explicitly with `flushPendingWork()`; only progress and waiting updates may be dropped.
- The host forwards a background-session wake to a `BackgroundTransferEvents` passed to the manager (accepted even before the manager exists) or to `handleBackgroundEvents(forSession:completionHandler:)`; both return `false` for other identifiers (see [App delegate wiring](#app-delegate-wiring)). The handler is called once, on the main actor, after the manager has applied every event of the wake. If the index cannot take the wake's events within `backgroundWakeBudget`, the handler is called anyway and the events stay unacknowledged with the session, which delivers them again. Events are received, and a wake's marker arms the budget, as they arrive, separately from their serial application, so the budget holds even while an index write is suspended; the reconciliation deadline is likewise recorded when it passes, without changing any record.
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

**Schema versioning.** `IndexSchema.currentVersion` is 2. Version 2 adds three record fields (`stoppedWhileUnconfirmed`, `restartDeferred`, `policyChangeDeferred`); version 1 data reads with them false and is stamped version 2, so a version 1 build refuses the index instead of dropping them. A newer stored version fails with `unsupportedSchema` and is left untouched; an unreadable or inconsistent index fails with `corruptIndex` and is preserved. The package never resets an index or deletes unrecognised files to recover.

**Finalisation journal.** `notStarted` → `captured` (temporary file moved into `staging/` before the system callback returns, committed with its byte count, validators and planned destination) → `committed`, or `rejected` when validation fails. Between the two, validation, flush and an atomic rename to the deterministic destination `media/item-<generation>[.ext]` run outside the command chain; they are idempotent, so an interruption anywhere in between is recovered by finalising the same generation again after the next start's replay (a file still in staging is validated and renamed; a file already renamed is validated again and committed). Only a committed record is `completed`, and only a committed record is handed out.

**Cleanup intent.** A file the package decides to delete (a stale or rejected capture, a replaced completed file, superseded resume data) is written to the index's `cleanupPaths` in the same commit that releases it, deleted afterwards, and removed from the list only after the deletion was verified. A file an outstanding `LocalFileLease` protects (for example a completed file replaced after it was found corrupt) is kept until that lease ends. A failed deletion is retried at later commands, `flushPendingWork()` and the next start. Files in `staging/` or `media/` that are neither owned nor listed are unknown: `unreferencedFiles()` reports them and nothing deletes them automatically.

## Concurrency

The manager is a `Sendable` facade over one actor. All mutable state is actor-isolated; dependencies are `Sendable` protocols; snapshots and events are immutable values. The URLSession delegate holds only immutable values: inside each callback it does the synchronous work that cannot wait (judging a finished response, moving its file into `staging/`, writing a receipt) and forwards every callback, in order, through one `AsyncStream` continuation to the session's actor, so arrival order is callback order without a task per callback. The library uses no `@unchecked Sendable`, `nonisolated(unsafe)` or detached tasks. Swift 6 language mode with complete checking is what enforces isolation; a source test additionally trips on those spellings and on imports other than Foundation (outside the one file each for SQLite3 and CryptoKit), as a lexical check only.

## Testing

```sh
swift test
```

The engine tests drive the manager with fakes: a scripted transfer session, an in-memory JSON index, an in-memory file system with fault injection, a manual clock and fixed jitter. None of them sleeps. They cover the command and event transitions exercised in the state machine suites, stale-generation rejection, captured-byte ownership, idempotence, ordering, persistence-before-effects, rejected index writes, restart reconciliation (buffered completions, lost bindings, an initially allowed path, interrupted stops and renames, reused task numbers, a withheld backlog marker), suspended finalisers racing removal, cancel and detach, replay before recovered validation, persisted cleanup intent, schema refusal, the storage root rule, leases across detach, retries, policy changes, background-wake completion and snapshot subscriptions. A separate test target compiles external adapters against the public surface only.

The adapter tests use real files in a temporary directory:

- the SQLite store: round trips of every record shape, schema refusal, a competing writer that commits a newer version or an invalid record while the opener waits for the write lock, foreign and unreadable files, populated indexes missing their counter or holding contradictory records (refused byte for byte unchanged, also in rollback-journal mode), the version 1 migration, symbolic links in place of the database or its log, an injected failure inside a transaction, progress coalescing, a copy taken with the connection open and a write torn inside a transaction;
- the file system: absence against failed inspection, path escapes through `..` and symbolic links, chunked reads and hashing, atomic replacement, a failed directory flush and classified errors;
- the finaliser: every validation failure (nothing renamed), the interrupted rename, a failed directory flush after the rename, deadlines, cancellation and injected full-disk, permission and protection failures;
- the transfer adapter, against a URLProtocol fixture: 200, redirect, missing length, slow first byte, mid-transfer disconnect, truncated body, 404, 500 and 503 with Retry-After, HTML served as success, 401 and 403, an unsolicited 206, 416, unusable resume data, a refused continuation, durable replay with stable sequence numbers and foreign tasks; range continuations are tested at the response-rule level;
- the background mode: the configuration of each mode, task descriptions with the session's identity, the wake-drained marker behind stored events and behind an event that cannot be stored yet, a marker owed to the next manager, and restarts recorded before a relaunch (no URLProtocol fixture can run a background transfer, so none is run);
- relaunch sequencing through the manager: the wake handler forwarded before the manager exists, before and after start, twice, for another identifier, with the wake's events buffered before start, with the marker before or after the budget or never, and on the main thread; task and index repair for a binding whose task is gone, a task without an index row (the package's own, and one naming another session), a capture without its journal, a journal without its capture and a completed row without its file;
- the transfer adapter's storage: real permission faults on the receipt, event and reservation writes interrupting the production capture pipeline (including a relaunch in between), corrupt or unreadable inbox entries, the delegate-queue barrier against an older operation that is not ready, and symbolic links in place of `transfer/`, `staging/` and resume data;
- end to end through the manager on the production adapters: completion and offline lookup across a restart, checksum mismatch, error pages, retries, refreshed URLs, a denied write, cancel before the first byte, external deletion, a protected file, a lease across removal, and recovery from seeded crash states (after capture, between rename and commit, a committed record whose file is gone) plus two that run the production operations (between commit and acknowledgement with acknowledgements suppressed, an index write that returns an error).

The `DownloadKitUITests` target tests the presentation model against a scripted controller (state mapping for every state, coalesced publishing, cancellation and release of observations, command forwarding and in-flight suppression, confirmed and group removal, policy choices, banners, failure reasons, strings and redaction) and its lease handling against a real manager on the production adapters. There is no UI snapshot test. The fixture server has its own tests (`swift test` in `sample/fixture-server`).

The transfer and end-to-end tests wait on URLSession's own threads with bounded real-time polling. They do not run a background session's transfers or an iOS device; relaunches are simulated by a fresh transport or manager over the same files.

## License

DownloadKit is released under the MIT license. See [LICENSE](LICENSE).
