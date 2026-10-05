//
//  TransferSessionHost.swift
//  DownloadKit
//
//  Owns one URLSession, its delegate and its durable inbox for the life of the transport. A
//  manager reads it through a `URLSessionTransferSession`; a later manager for the same
//  identifier gets a fresh session object over the same host, which replays every
//  unacknowledged event with its original sequence number.
//
//  Storage failures: a terminal event is delivered only after it was written to the inbox
//  under its sequence number. An event whose write (or whose sequence reservation) fails stays
//  pending, in order, with its receipt kept on disk; it is retried with the same sequence
//  number, and nothing after it is delivered meanwhile (advisory events are dropped). An inbox
//  that cannot be read at start is never treated as empty. While anything is pending or the
//  inbox is unread, the backlog marker is withheld and ``TransferSessionEvent/Payload/backlogUnavailable``
//  is sent instead; the marker follows once storage recovered.
//
//  Background wakes: the system's wake-drained callback becomes a
//  ``TransferSessionEvent/Payload/backgroundEventsFinished`` marker that joins the same ordered
//  queue as terminal events, so it is never delivered ahead of an event still waiting to be
//  stored. A marker that arrives while no manager is subscribed is delivered to the next one,
//  after its replay.
//
//  Restarts: a refused continuation is recorded durably inside the callback (see
//  ``RestartIntent``) and replaced by a fresh task under the same description. After a
//  relaunch the intents are read back: the refused task's late completion is ignored and a
//  cancel of the refused task reaches its replacement.
//

import Foundation

actor TransferSessionHost {
    /// A terminal event, or a wake marker (`event == nil`), not yet delivered, with the
    /// sequence number it was given.
    private struct PendingEvent {
        let event: TransferEvent?
        let receipt: UUID?
        var sequence: UInt64?
    }

    let identifier: String
    let storageRoot: URL
    /// Whether the system keeps this session's tasks across launches (background mode), so a
    /// restart recorded by an earlier process still names a live task.
    let tasksOutliveProcess: Bool
    private let inbox: TransferInbox
    private let session: URLSession
    private let delegateQueue: OperationQueue
    private let channel: AsyncStream<DelegateCallback>.Continuation
    private let callbacks: AsyncStream<DelegateCallback>
    private let sessionNetworkAccess: NetworkPolicy
    private let storageRetryDelay: UInt64

    private var consumer: Task<Void, Never>?
    private var subscriber: AsyncStream<TransferSessionEvent>.Continuation?
    private var subscription: UUID?
    /// The sequence number of the last entry yielded to the current subscriber.
    private var lastYielded: UInt64 = 0
    private var unavailableReported = false
    /// The backlog marker of this subscription, withheld while storage is incomplete.
    private var owedMarker: UUID?
    /// Whether the durable inbox was read completely.
    private var loaded = false
    /// Stored terminal events not yet acknowledged, in sequence order.
    private var unacknowledged: [StoredEvent] = []
    /// Terminal events whose write failed, in order; delivered once written.
    private var pending: [PendingEvent] = []
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0
    private var handledReceipts: Set<UUID> = []
    private var nextSequence: UInt64 = 1
    private var reservedSequence: UInt64 = 0
    /// Tasks whose terminal outcome was already reported; their completion callback is ignored.
    private var reportedTasks: Set<Int> = []
    /// Submissions of running tasks, for a restart from zero.
    private var submissions: [Int: TransferSubmission] = [:]
    /// Task identifiers the manager knows, mapped to the task that replaced them on a restart.
    private var replacements: [Int: Int] = [:]
    /// Durable restarts, by refused task, read back after a relaunch or written in this process.
    private var restarts: [Int: RestartIntent] = [:]
    /// A wake marker arrived while no manager was subscribed.
    private var wakeMarkerOwed = false
    private var lastProgress: [Int: Int64] = [:]

    /// `tasksOutliveProcess` overrides the mode's answer (tests only: a foreground session
    /// standing in for a background one).
    init(identifier: String, storageRoot: URL, options: URLSessionTransport.Options, storageRetryDelay: TimeInterval = 2, tasksOutliveProcess: Bool? = nil) throws {
        self.identifier = identifier
        self.storageRoot = storageRoot
        self.tasksOutliveProcess = tasksOutliveProcess ?? (options.mode == .background)
        self.sessionNetworkAccess = options.sessionNetworkAccess
        self.storageRetryDelay = UInt64(max(0.001, storageRetryDelay) * 1_000_000_000)
        let inbox = TransferInbox(storageRoot: storageRoot, sessionIdentifier: identifier)
        try inbox.prepare()
        self.inbox = inbox
        let (callbacks, channel) = AsyncStream.makeStream(of: DelegateCallback.self)
        self.callbacks = callbacks
        self.channel = channel
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "DownloadKit.transfer.\(identifier)"
        self.delegateQueue = queue
        var inspector = ResponseInspector()
        inspector.rejectedMediaTypes = options.rejectedMediaTypes
        let delegate = TransferDelegate(sessionIdentifier: identifier, channel: channel, capture: FileCapture(storageRoot: storageRoot, inbox: inbox, inspector: inspector, now: options.now))
        self.session = URLSession(configuration: options.makeConfiguration(identifier: identifier), delegate: delegate, delegateQueue: queue)
    }

    /// Loads the durable inbox, turns leftover receipts into events, then starts reading the
    /// delegate's callbacks in order.
    func start() {
        guard consumer == nil else { return }
        loadInbox()
        let callbacks = self.callbacks
        consumer = Task { [weak self] in
            for await callback in callbacks {
                guard let self else { return }
                await self.handle(callback)
            }
        }
    }

    /// Reads the inbox once. A failure leaves it unread (nothing is assumed) and is retried.
    private func loadInbox() {
        guard !loaded else { return }
        let contents: TransferInbox.Contents
        do {
            contents = try inbox.load()
        } catch {
            scheduleStorageRetry()
            return
        }
        loaded = true
        let highest = contents.events.last?.sequence ?? 0
        nextSequence = max(contents.state.reservedSequence, highest) + 1
        reservedSequence = nextSequence - 1
        unacknowledged = contents.events
        for intent in contents.restarts {
            if tasksOutliveProcess {
                restarts[intent.taskIdentifier] = intent
                if let replacement = intent.replacement { replacements[intent.taskIdentifier] = replacement }
            } else {
                // No task of a foreground session outlives its process.
                inbox.removeRestart(intent.taskIdentifier)
            }
        }
        // A subscriber that arrived while the inbox was unread has received nothing yet.
        for stored in contents.events {
            if let event = stored.event.event { yield(stored.sequence, .transfer(event)) }
        }
        let known = Set(contents.events.compactMap(\.receipt))
        var leftovers: [PendingEvent] = []
        for receipt in contents.receipts {
            handledReceipts.insert(receipt.id)
            if known.contains(receipt.id) {
                // The event was stored before the receipt could be deleted.
                inbox.removeReceipt(receipt.id)
            } else if let event = receipt.event.event {
                leftovers.append(PendingEvent(event: event, receipt: receipt.id, sequence: nil))
            }
        }
        // Leftover receipts are older than anything received since.
        pending = leftovers + pending
        flushPending()
    }

    // MARK: Subscription

    /// A new event stream for one manager: every unacknowledged event with its original
    /// sequence number, then live events, with the backlog marker once the system's task list was
    /// read and every callback queued before that was forwarded (a barrier on the delegate
    /// queue), and once every captured outcome is durably stored.
    func subscribe() -> AsyncStream<TransferSessionEvent> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSessionEvent.self)
        subscriber = continuation
        let token = UUID()
        subscription = token
        lastYielded = 0
        unavailableReported = false
        owedMarker = nil
        if loaded {
            for stored in unacknowledged {
                guard let event = stored.event.event else { continue }
                yield(stored.sequence, .transfer(event))
            }
        }
        if wakeMarkerOwed {
            // Behind the replay and anything still waiting to be stored.
            wakeMarkerOwed = false
            pending.append(PendingEvent(event: nil, receipt: nil, sequence: nil))
        }
        let session = self.session
        let queue = delegateQueue
        let channel = self.channel
        Task {
            _ = await Self.tasks(of: session)
            // A barrier, not an ordinary operation: it runs only after every operation queued
            // before it has finished, whatever their readiness or priority.
            queue.addBarrierBlock { channel.yield(.barrier(token)) }
        }
        retryStorage()
        return stream
    }

    // MARK: Commands

    func submit(_ submission: TransferSubmission) throws -> Int {
        var resumeData: Data?
        var resumeURL: URL?
        if let path = submission.resumeDataPath,
           let url = try? inbox.confined(storageRoot.appendingPathComponent(path.rawValue, isDirectory: false)) {
            resumeURL = url
            if let data = try? Data(contentsOf: url), Self.isUsableResumeData(data), allowsResumption(under: submission.policy) {
                resumeData = data
            }
        }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: Self.request(for: submission))
        }
        task.taskDescription = submission.taskDescription(sessionIdentifier: identifier)
        submissions[task.taskIdentifier] = submission
        task.resume()
        // The task holds its own copy of the resume data; the file is no longer needed.
        if let resumeURL { try? FileManager.default.removeItem(at: resumeURL) }
        return task.taskIdentifier
    }

    func cancel(taskIdentifier: Int, producingResumeData: Bool) async {
        let target = replacements[taskIdentifier] ?? taskIdentifier
        let tasks = await Self.tasks(of: session)
        // Unknown tasks and tasks this package did not create are left alone.
        guard let task = tasks.first(where: { $0.taskIdentifier == target }),
              let reference = TransferTaskReference(taskDescription: task.taskDescription, taskIdentifier: target, sessionIdentifier: identifier) else { return }
        guard producingResumeData, let download = task as? URLSessionDownloadTask else {
            task.cancel()
            return
        }
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            download.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
        }
        guard let data, !data.isEmpty else { return }
        let path = RelativePath.staging()
        do {
            try data.write(to: try inbox.confined(storageRoot.appendingPathComponent(path.rawValue, isDirectory: false)), options: .atomic)
        } catch {
            return
        }
        deliver(.resumeDataCaptured(reference, path), receipt: nil)
    }

    func systemTasks() async -> [SystemTransferTask] {
        await Self.tasks(of: session).map { SystemTransferTask(taskIdentifier: $0.taskIdentifier, taskDescription: $0.taskDescription) }
    }

    func acknowledge(through sequence: UInt64) {
        let released = unacknowledged.filter { $0.sequence <= sequence }
        unacknowledged.removeAll { $0.sequence <= sequence }
        for event in released { inbox.removeEvent(event.sequence) }
        retryStorage()
    }

    /// Ends the system session; its delegate then finishes the event stream.
    func invalidate(cancellingTasks: Bool) {
        retryTask?.cancel()
        retryTask = nil
        if cancellingTasks {
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: Test hooks

    var urlSession: URLSession { session }
    var unacknowledgedSequences: [UInt64] { unacknowledged.map(\.sequence) }
    var pendingCount: Int { pending.count }
    var restartIntents: [RestartIntent] { restarts.values.sorted { $0.taskIdentifier < $1.taskIdentifier } }
    func replacement(for taskIdentifier: Int) -> Int? { replacements[taskIdentifier] }
    var isInboxLoaded: Bool { loaded }
    nonisolated var callbackChannel: AsyncStream<DelegateCallback>.Continuation { channel }
    nonisolated var callbackQueue: OperationQueue { delegateQueue }

    func inject(_ callback: DelegateCallback) {
        channel.yield(callback)
    }

    // MARK: Storage retry

    /// Tries again to read an unread inbox and to store pending events.
    func retryStorage() {
        if !loaded {
            loadInbox()
        } else {
            flushPending()
        }
    }

    private func scheduleStorageRetry() {
        guard retryTask == nil else { return }
        // Bounded backoff: the base delay doubled per failure, at most 32 times the base.
        let delay = storageRetryDelay << UInt64(min(retryAttempts, 5))
        retryAttempts += 1
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.storageRetryFired()
        }
    }

    private func storageRetryFired() {
        retryTask = nil
        retryStorage()
    }

    // MARK: Callbacks

    private func handle(_ callback: DelegateCallback) {
        switch callback {
        case .progress(let taskIdentifier, let description, let written, let expected):
            guard let reference = reference(description, taskIdentifier) else { return }
            // Advisory: forwarded at most once per 64 KiB or 1 %, and at the end.
            let step = max(65_536, expected > 0 ? expected / 100 : 0)
            if let last = lastProgress[taskIdentifier], written - last < step, written != expected { return }
            lastProgress[taskIdentifier] = written
            emitAdvisory(.transfer(.progress(reference, bytesWritten: written, expectedBytes: expected > 0 ? expected : nil)))

        case .waiting(let taskIdentifier, let description):
            guard let reference = reference(description, taskIdentifier) else { return }
            emitAdvisory(.transfer(.waiting(reference, .connectivity)))

        case .receipt(let receipt, let taskIdentifier, _):
            reportedTasks.insert(taskIdentifier)
            submissions[taskIdentifier] = nil
            lastProgress[taskIdentifier] = nil
            finishRestarts(replacedBy: taskIdentifier)
            guard handledReceipts.insert(receipt.id).inserted, let event = receipt.event.event else { return }
            if replacements[taskIdentifier] != nil {
                // The task was replaced by a restart: its outcome belongs to nobody. A file it
                // captured was never reported, so the adapter deletes it.
                if case .finished(_, let captured, _, _) = event,
                   let url = try? inbox.confined(storageRoot.appendingPathComponent(captured.rawValue, isDirectory: false)) {
                    try? FileManager.default.removeItem(at: url)
                }
                inbox.removeReceipt(receipt.id)
                return
            }
            // A receipt that could not be written is kept only in memory: the event must be
            // stored before anything after it is delivered.
            deliver(event, receipt: receipt.id)

        case .restart(let taskIdentifier, let description, let request):
            reportedTasks.insert(taskIdentifier)
            lastProgress[taskIdentifier] = nil
            restart(taskIdentifier, description: description, request: request)

        case .completed(let taskIdentifier, let description, let failure):
            lastProgress[taskIdentifier] = nil
            guard reportedTasks.remove(taskIdentifier) == nil else { return }
            submissions[taskIdentifier] = nil
            guard let reference = reference(description, taskIdentifier) else { return }
            // The refused task of a restart recorded before a relaunch: its replacement reports.
            if let intent = restarts[taskIdentifier], intent.matches(reference) { return }
            finishRestarts(replacedBy: taskIdentifier)
            // A task that ended without a usable file and without an error had no usable response.
            deliver(.failed(reference, failure ?? .invalidResponse), receipt: nil)

        case .eventsFinished:
            pending.append(PendingEvent(event: nil, receipt: nil, sequence: nil))
            flushPending()

        case .barrier(let token):
            guard token == subscription else { return }
            deliverMarker(token)

        case .invalidated:
            subscriber?.finish()
            subscriber = nil
        }
    }

    /// Starts the attempt again from zero under the same description. The manager keeps using the
    /// task identifier it was given; it is mapped to the replacement, durably. The request is the
    /// submission's when this process made it, otherwise the system's copy of the refused
    /// task's request without its range headers.
    private func restart(_ taskIdentifier: Int, description: String?, request original: URLRequest?) {
        guard let reference = reference(description, taskIdentifier) else { return }
        let request: URLRequest
        var fresh: TransferSubmission?
        if let submission = submissions.removeValue(forKey: taskIdentifier) {
            let renewed = TransferSubmission(itemID: submission.itemID, generation: submission.generation, url: submission.url, policy: submission.policy, resumeDataPath: nil, expectedLength: submission.expectedLength)
            fresh = renewed
            request = Self.request(for: renewed)
        } else if let original, original.url != nil {
            request = Self.restartRequest(from: original)
        } else {
            inbox.removeRestart(taskIdentifier)
            restarts[taskIdentifier] = nil
            deliver(.failed(reference, .http(status: 416, retryAfter: nil)), receipt: nil)
            return
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = TransferTaskReference.taskDescription(itemID: reference.itemID, generation: reference.generation, sessionIdentifier: identifier)
        if let fresh { submissions[task.taskIdentifier] = fresh }
        for (known, current) in replacements where current == taskIdentifier { replacements[known] = task.taskIdentifier }
        replacements[taskIdentifier] = task.taskIdentifier
        // Best effort: if the intent cannot be written the restart still runs in this process.
        var intent = restarts[taskIdentifier] ?? RestartIntent(taskIdentifier: taskIdentifier, itemID: reference.itemID.rawValue, generation: reference.generation, replacement: nil)
        intent.replacement = task.taskIdentifier
        restarts[taskIdentifier] = intent
        try? inbox.write(intent)
        task.resume()
        // The refused task normally ended already; make sure it cannot report anything else.
        let session = self.session
        Task {
            await Self.tasks(of: session).first { $0.taskIdentifier == taskIdentifier }?.cancel()
        }
    }

    /// The replacement `taskIdentifier` reported its outcome: the restarts it finished are done.
    private func finishRestarts(replacedBy taskIdentifier: Int) {
        for intent in restarts.values where intent.replacement == taskIdentifier {
            restarts[intent.taskIdentifier] = nil
            inbox.removeRestart(intent.taskIdentifier)
        }
    }

    /// The task's item and attempt in this session, `nil` for a foreign task.
    private func reference(_ description: String?, _ taskIdentifier: Int) -> TransferTaskReference? {
        TransferTaskReference(taskDescription: description, taskIdentifier: taskIdentifier, sessionIdentifier: identifier)
    }

    /// A refused continuation's request, as a fresh request from zero.
    static func restartRequest(from original: URLRequest) -> URLRequest {
        var request = original
        request.setValue(nil, forHTTPHeaderField: "Range")
        request.setValue(nil, forHTTPHeaderField: "If-Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    // MARK: Emitting

    /// Queues a terminal event behind any pending one, then stores and delivers in order.
    private func deliver(_ event: TransferEvent, receipt: UUID?) {
        pending.append(PendingEvent(event: event, receipt: receipt, sequence: nil))
        flushPending()
    }

    /// Stores and delivers pending terminal events in order, stopping at the first failure.
    /// A failed event keeps its sequence number for the retry, so no number is used twice.
    private func flushPending() {
        guard loaded else {
            scheduleStorageRetry()
            return
        }
        while let head = pending.first {
            do {
                let sequence = try head.sequence ?? allocateSequence()
                pending[0].sequence = sequence
                guard let event = head.event else {
                    // A wake marker: nothing to store, everything before it is stored.
                    pending.removeFirst()
                    yield(sequence, .backgroundEventsFinished)
                    continue
                }
                // Terminal events always have a stored form.
                let entry = StoredEvent(sequence: sequence, receipt: head.receipt, event: StoredTransferEvent(event)!)
                try inbox.write(entry)
                unacknowledged.append(entry)
                pending.removeFirst()
                yield(sequence, .transfer(event))
                if let receipt = head.receipt { inbox.removeReceipt(receipt) }
            } catch {
                scheduleStorageRetry()
                return
            }
        }
        retryTask?.cancel()
        retryTask = nil
        retryAttempts = 0
        if let owed = owedMarker, owed == subscription {
            owedMarker = nil
            deliverMarker(owed)
        }
    }

    /// The backlog marker, only when the inbox was read completely and nothing is pending.
    /// Otherwise the subscriber is told once that the backlog is unavailable, and the marker
    /// follows when storage recovered.
    private func deliverMarker(_ token: UUID) {
        if loaded, pending.isEmpty, let sequence = try? allocateSequence() {
            yield(sequence, .backlogDelivered)
            return
        }
        owedMarker = token
        if !unavailableReported {
            unavailableReported = true
            // Not a new position in the stream: it repeats the last delivered sequence number.
            subscriber?.yield(TransferSessionEvent(sequence: lastYielded, payload: .backlogUnavailable))
        }
        scheduleStorageRetry()
    }

    /// Delivers an advisory event; nothing is stored. Dropped while a terminal event is pending
    /// (it would otherwise overtake it) or when no number can be reserved.
    private func emitAdvisory(_ payload: TransferSessionEvent.Payload) {
        guard loaded, pending.isEmpty, let sequence = try? allocateSequence() else { return }
        yield(sequence, payload)
    }

    private func yield(_ sequence: UInt64, _ payload: TransferSessionEvent.Payload) {
        guard let subscriber else {
            // Stored events are replayed to the next subscriber; a wake marker is owed to it.
            if payload == .backgroundEventsFinished { wakeMarkerOwed = true }
            return
        }
        if case .terminated = subscriber.yield(TransferSessionEvent(sequence: sequence, payload: payload)),
           payload == .backgroundEventsFinished {
            // The manager stopped reading (detached): the next one gets the marker.
            wakeMarkerOwed = true
        }
        lastYielded = sequence
    }

    /// Sequence numbers are reserved on disk in blocks before use, so they are never reused,
    /// even by events that are not stored. Throws when the reservation cannot be written.
    private func allocateSequence() throws -> UInt64 {
        if nextSequence > reservedSequence {
            let reserved = nextSequence + 255
            try inbox.write(TransferInbox.State(reservedSequence: reserved))
            reservedSequence = reserved
        }
        defer { nextSequence += 1 }
        return nextSequence
    }

    // MARK: Helpers

    private static func tasks(of session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    /// Resume data is opaque; it is only checked to be a property list before it is used.
    /// Anything else falls back to a fresh request.
    static func isUsableResumeData(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return !plist.isEmpty
    }

    /// A task created from resume data cannot carry per-request network flags; it inherits the
    /// session's. It is used only when the session's flags are no more permissive than the
    /// item's policy, so resumption never widens the networks an item may use.
    private func allowsResumption(under policy: NetworkPolicy) -> Bool {
        (!sessionNetworkAccess.allowsCellular || policy.allowsCellular)
            && (!sessionNetworkAccess.allowsExpensive || policy.allowsExpensive)
            && (!sessionNetworkAccess.allowsConstrained || policy.allowsConstrained)
    }

    /// The request for a fresh attempt, with the item's policy applied.
    static func request(for submission: TransferSubmission) -> URLRequest {
        var request = URLRequest(url: submission.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = submission.policy.allowsCellular
        request.allowsExpensiveNetworkAccess = submission.policy.allowsExpensive
        request.allowsConstrainedNetworkAccess = submission.policy.allowsConstrained
        request.networkServiceType = submission.policy.scheduling == .deferred ? .background : .default
        return request
    }
}
