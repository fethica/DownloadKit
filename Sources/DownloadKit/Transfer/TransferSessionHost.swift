//
//  TransferSessionHost.swift
//  DownloadKit
//
//  Owns one URLSession, its delegate and its durable inbox for the life of the transport. A
//  manager reads it through a `URLSessionTransferSession`; a later manager for the same
//  identifier gets a fresh session object over the same host, which replays every
//  unacknowledged event with its original sequence number.
//

import Foundation

actor TransferSessionHost {
    let identifier: String
    let storageRoot: URL
    private let inbox: TransferInbox
    private let session: URLSession
    private let delegateQueue: OperationQueue
    private let channel: AsyncStream<DelegateCallback>.Continuation
    private let callbacks: AsyncStream<DelegateCallback>
    private let sessionNetworkAccess: NetworkPolicy

    private var consumer: Task<Void, Never>?
    private var subscriber: AsyncStream<TransferSessionEvent>.Continuation?
    private var subscription: UUID?
    /// Stored terminal events not yet acknowledged, in sequence order.
    private var unacknowledged: [StoredEvent] = []
    private var handledReceipts: Set<UUID> = []
    private var nextSequence: UInt64 = 1
    private var reservedSequence: UInt64 = 0
    /// Tasks whose terminal outcome was already reported; their completion callback is ignored.
    private var reportedTasks: Set<Int> = []
    /// Submissions of running tasks, for a restart from zero.
    private var submissions: [Int: TransferSubmission] = [:]
    /// Task identifiers the manager knows, mapped to the task that replaced them on a restart.
    private var replacements: [Int: Int] = [:]
    private var lastProgress: [Int: Int64] = [:]

    init(identifier: String, storageRoot: URL, options: URLSessionTransport.Options) throws {
        self.identifier = identifier
        self.storageRoot = storageRoot
        self.sessionNetworkAccess = options.sessionNetworkAccess
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
        let delegate = TransferDelegate(channel: channel, capture: FileCapture(storageRoot: storageRoot, inbox: inbox, inspector: inspector, now: options.now))
        self.session = URLSession(configuration: options.makeConfiguration(identifier: identifier), delegate: delegate, delegateQueue: queue)
    }

    /// Loads the durable inbox, turns leftover receipts into events, then starts reading the
    /// delegate's callbacks in order.
    func start() {
        guard consumer == nil else { return }
        let stored = inbox.storedEvents()
        let highest = stored.last?.sequence ?? 0
        nextSequence = max(inbox.readState().reservedSequence, highest) + 1
        reservedSequence = nextSequence - 1
        unacknowledged = stored
        let known = Set(stored.compactMap(\.receipt))
        for receipt in inbox.pendingReceipts() {
            handledReceipts.insert(receipt.id)
            if known.contains(receipt.id) {
                // The event was stored before the receipt could be deleted.
                inbox.removeReceipt(receipt.id)
            } else if let event = receipt.event.event {
                store(event, receipt: receipt.id)
                inbox.removeReceipt(receipt.id)
            }
        }
        let callbacks = self.callbacks
        consumer = Task { [weak self] in
            for await callback in callbacks {
                guard let self else { return }
                await self.handle(callback)
            }
        }
    }

    // MARK: Subscription

    /// A new event stream for one manager: every unacknowledged event with its original
    /// sequence number, then live events, with the backlog marker once the system's task list was
    /// read and every callback queued before that was forwarded.
    func subscribe() -> AsyncStream<TransferSessionEvent> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSessionEvent.self)
        subscriber = continuation
        let token = UUID()
        subscription = token
        for stored in unacknowledged {
            guard let event = stored.event.event else { continue }
            continuation.yield(TransferSessionEvent(sequence: stored.sequence, payload: .transfer(event)))
        }
        let session = self.session
        let queue = delegateQueue
        let channel = self.channel
        Task {
            _ = await Self.tasks(of: session)
            queue.addOperation { channel.yield(.barrier(token)) }
        }
        return stream
    }

    // MARK: Commands

    func submit(_ submission: TransferSubmission) throws -> Int {
        var resumeData: Data?
        var resumeURL: URL?
        if let path = submission.resumeDataPath {
            let url = storageRoot.appendingPathComponent(path.rawValue, isDirectory: false)
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
        task.taskDescription = submission.taskDescription
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
              let reference = TransferTaskReference(taskDescription: task.taskDescription, taskIdentifier: target) else { return }
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
            try data.write(to: storageRoot.appendingPathComponent(path.rawValue, isDirectory: false), options: .atomic)
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
    }

    /// Ends the system session; its delegate then finishes the event stream.
    func invalidate(cancellingTasks: Bool) {
        if cancellingTasks {
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: Test hooks

    var urlSession: URLSession { session }
    var unacknowledgedSequences: [UInt64] { unacknowledged.map(\.sequence) }

    func inject(_ callback: DelegateCallback) {
        channel.yield(callback)
    }

    // MARK: Callbacks

    private func handle(_ callback: DelegateCallback) {
        switch callback {
        case .progress(let taskIdentifier, let description, let written, let expected):
            guard let reference = TransferTaskReference(taskDescription: description, taskIdentifier: taskIdentifier) else { return }
            // Advisory: forwarded at most once per 64 KiB or 1 %, and at the end.
            let step = max(65_536, expected > 0 ? expected / 100 : 0)
            if let last = lastProgress[taskIdentifier], written - last < step, written != expected { return }
            lastProgress[taskIdentifier] = written
            emit(.transfer(.progress(reference, bytesWritten: written, expectedBytes: expected > 0 ? expected : nil)))

        case .waiting(let taskIdentifier, let description):
            guard let reference = TransferTaskReference(taskDescription: description, taskIdentifier: taskIdentifier) else { return }
            emit(.transfer(.waiting(reference, .connectivity)))

        case .receipt(let receipt, let taskIdentifier):
            reportedTasks.insert(taskIdentifier)
            submissions[taskIdentifier] = nil
            lastProgress[taskIdentifier] = nil
            guard handledReceipts.insert(receipt.id).inserted, let event = receipt.event.event else { return }
            if replacements[taskIdentifier] != nil {
                // The task was replaced by a restart: its outcome belongs to nobody. A file it
                // captured was never reported, so the adapter deletes it.
                if case .finished(_, let captured, _, _) = event {
                    try? FileManager.default.removeItem(at: storageRoot.appendingPathComponent(captured.rawValue, isDirectory: false))
                }
                inbox.removeReceipt(receipt.id)
                return
            }
            deliver(event, receipt: receipt.id)
            inbox.removeReceipt(receipt.id)

        case .restart(let taskIdentifier, let description):
            reportedTasks.insert(taskIdentifier)
            lastProgress[taskIdentifier] = nil
            restart(taskIdentifier, description: description)

        case .completed(let taskIdentifier, let description, let failure):
            lastProgress[taskIdentifier] = nil
            guard reportedTasks.remove(taskIdentifier) == nil else { return }
            submissions[taskIdentifier] = nil
            guard let reference = TransferTaskReference(taskDescription: description, taskIdentifier: taskIdentifier) else { return }
            // A task that ended without a usable file and without an error had no usable response.
            deliver(.failed(reference, failure ?? .invalidResponse), receipt: nil)

        case .barrier(let token):
            guard token == subscription else { return }
            emit(.backlogDelivered)

        case .invalidated:
            subscriber?.finish()
            subscriber = nil
        }
    }

    /// Starts the attempt again from zero under the same description. The manager keeps using the
    /// task identifier it was given; it is mapped to the replacement.
    private func restart(_ taskIdentifier: Int, description: String?) {
        guard let reference = TransferTaskReference(taskDescription: description, taskIdentifier: taskIdentifier) else { return }
        guard let submission = submissions.removeValue(forKey: taskIdentifier) else {
            deliver(.failed(reference, .http(status: 416, retryAfter: nil)), receipt: nil)
            return
        }
        let fresh = TransferSubmission(itemID: submission.itemID, generation: submission.generation, url: submission.url, policy: submission.policy, resumeDataPath: nil, expectedLength: submission.expectedLength)
        let task = session.downloadTask(with: Self.request(for: fresh))
        task.taskDescription = fresh.taskDescription
        submissions[task.taskIdentifier] = fresh
        for (known, current) in replacements where current == taskIdentifier { replacements[known] = task.taskIdentifier }
        replacements[taskIdentifier] = task.taskIdentifier
        task.resume()
        // The refused task normally ended already; make sure it cannot report anything else.
        let session = self.session
        Task {
            await Self.tasks(of: session).first { $0.taskIdentifier == taskIdentifier }?.cancel()
        }
    }

    // MARK: Emitting

    /// Stores a terminal event, then delivers it.
    private func deliver(_ event: TransferEvent, receipt: UUID?) {
        let sequence = store(event, receipt: receipt)
        subscriber?.yield(TransferSessionEvent(sequence: sequence, payload: .transfer(event)))
    }

    @discardableResult
    private func store(_ event: TransferEvent, receipt: UUID?) -> UInt64 {
        let sequence = allocateSequence()
        if let stored = StoredTransferEvent(event) {
            let entry = StoredEvent(sequence: sequence, receipt: receipt, event: stored)
            // If the write fails the event is still delivered and kept in memory until acknowledged.
            try? inbox.write(entry)
            unacknowledged.append(entry)
        }
        return sequence
    }

    /// Delivers an advisory event or a marker; nothing is stored.
    private func emit(_ payload: TransferSessionEvent.Payload) {
        let sequence = allocateSequence()
        subscriber?.yield(TransferSessionEvent(sequence: sequence, payload: payload))
    }

    /// Sequence numbers are reserved on disk in blocks before use, so they are never reused,
    /// even by events that are not stored.
    private func allocateSequence() -> UInt64 {
        if nextSequence > reservedSequence {
            let reserved = nextSequence + 255
            try? inbox.write(TransferInbox.State(reservedSequence: reserved))
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
