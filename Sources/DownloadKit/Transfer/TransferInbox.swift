//
//  TransferInbox.swift
//  DownloadKit
//
//  The adapter's durable record of terminal events, on disk under
//  `<root>/transfer/<session>/`:
//  - `receipts/`: one file per terminal outcome, written synchronously inside the system
//    callback before the downloaded file is moved into `staging/` (see the order below), and
//    before the callback returns. A receipt has no sequence number yet.
//  - `events/`: one file per sequenced terminal event, written before the event is delivered.
//    A file is deleted once the manager acknowledged its sequence number.
//  - `state.json`: the highest reserved sequence number, so numbers are never reused across
//    launches.
//  - `restarts/`: one file per refused continuation (416, or a range answer that cannot be
//    trusted), written inside the system callback before it returns, naming the task, its item
//    and attempt, and later the replacement task. It lets a relaunched process recognise the
//    refused task's late completion and the replacement, instead of reporting a failure. No URL
//    is written: the refusal is handed to the manager, which submits the replacement under the
//    item's current source through its `transferURL` hook, so a fresh URL is resolved each time.
//
//  Order inside the callback: the receipt (naming the staging file the capture will use) is
//  written before the temporary file is moved, so a moved file always has a durable association.
//  If the receipt cannot be written nothing is moved and the attempt is reported as a storage
//  failure. A receipt is deleted only after its sequenced event was written.
//
//  Crash windows: a receipt without an event becomes an event on the next start (a receipt
//  whose file was never moved then names a missing capture, which finalisation rejects); a
//  receipt whose event exists (the process ended between writing the event and deleting the
//  receipt) is only deleted. No URL, header or credential is written here; resume data is
//  stored by the session as the opaque blob the system produced.
//

import Foundation

/// A terminal event in a form that can be written to disk.
struct StoredTransferEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case finished
        case failed
        case resumeData
    }

    var kind: Kind
    var itemID: String
    var generation: UInt64
    var taskIdentifier: Int
    var path: RelativePath?
    var bytes: Int64?
    var validators: ResponseValidators?
    var failure: StoredFailure?

    /// `nil` for advisory events, which are never stored.
    init?(_ event: TransferEvent) {
        switch event {
        case .progress, .waiting:
            return nil
        case .finished(let reference, let captured, let bytes, let validators):
            self.init(kind: .finished, reference: reference)
            self.path = captured
            self.bytes = bytes
            self.validators = validators
        case .failed(let reference, let failure):
            self.init(kind: .failed, reference: reference)
            self.failure = StoredFailure(failure)
        case .resumeDataCaptured(let reference, let path):
            self.init(kind: .resumeData, reference: reference)
            self.path = path
        }
    }

    private init(kind: Kind, reference: TransferTaskReference) {
        self.kind = kind
        self.itemID = reference.itemID.rawValue
        self.generation = reference.generation
        self.taskIdentifier = reference.taskIdentifier
    }

    /// The event, or `nil` when the stored fields do not describe one.
    var event: TransferEvent? {
        guard let id = try? DownloadID(itemID) else { return nil }
        let reference = TransferTaskReference(itemID: id, generation: generation, taskIdentifier: taskIdentifier)
        switch kind {
        case .finished:
            guard let path, let bytes else { return nil }
            return .finished(reference, captured: path, bytes: bytes, validators: validators)
        case .failed:
            guard let failure else { return nil }
            return .failed(reference, failure.failure)
        case .resumeData:
            guard let path else { return nil }
            return .resumeDataCaptured(reference, path)
        }
    }
}

/// A ``TransferFailure`` in a form that can be written to disk.
struct StoredFailure: Codable, Hashable, Sendable {
    var kind: String
    var code: Int?
    var retryAfter: TimeInterval?
    var storage: StorageFailureReason?

    init(_ failure: TransferFailure) {
        switch failure {
        case .network(let code): kind = "network"; self.code = code
        case .http(let status, let retryAfter): kind = "http"; code = status; self.retryAfter = retryAfter
        case .storage(let reason): kind = "storage"; storage = reason
        case .integrity: kind = "integrity"
        case .invalidResponse: kind = "invalid_response"
        case .cancelled: kind = "cancelled"
        case .policyBlocked: kind = "policy_blocked"
        case .credentialsUnavailable: kind = "credentials_unavailable"
        case .unknown: kind = "unknown"
        }
    }

    var failure: TransferFailure {
        switch kind {
        case "network": return .network(code: code)
        case "http": return .http(status: code ?? 0, retryAfter: retryAfter)
        case "storage": return .storage(storage ?? .other)
        case "integrity": return .integrity
        case "invalid_response": return .invalidResponse
        case "cancelled": return .cancelled
        case "policy_blocked": return .policyBlocked
        case "credentials_unavailable": return .credentialsUnavailable
        default: return .unknown
        }
    }
}

/// One terminal outcome recorded inside the system callback.
struct CaptureReceipt: Codable, Hashable, Sendable {
    let id: UUID
    let written: Date
    let event: StoredTransferEvent
}

/// A refused continuation that is being started again from zero.
struct RestartIntent: Codable, Hashable, Sendable {
    /// The task whose continuation was refused.
    let taskIdentifier: Int
    let itemID: String
    let generation: UInt64
    /// The task that replaced it, once created.
    var replacement: Int?

    /// Whether `reference` names the same item and attempt (a reused task number does not).
    func matches(_ reference: TransferTaskReference) -> Bool {
        reference.itemID.rawValue == itemID && reference.generation == generation
    }
}

/// One sequenced terminal event.
struct StoredEvent: Codable, Hashable, Sendable {
    let sequence: UInt64
    /// The receipt this event was made from, when there was one.
    let receipt: UUID?
    let event: StoredTransferEvent
}

/// The files of one session's inbox. Every operation is synchronous and small, and every path is
/// checked with ``PathConfinement`` against the storage root before it is used.
///
/// Failure rule: nothing here turns a failure into absence. A directory or entry that cannot be
/// read, or an entry that does not decode into a complete event, makes ``load()`` throw; the
/// session then reports its backlog unavailable instead of an empty one. Writes throw, and the
/// session keeps the event (and its receipt) until a write succeeds.
struct TransferInbox: Sendable {
    struct State: Codable, Hashable, Sendable {
        var reservedSequence: UInt64
    }

    /// Everything the inbox holds.
    struct Contents: Sendable {
        /// Stored events, in sequence order.
        var events: [StoredEvent]
        /// Receipts, oldest first.
        var receipts: [CaptureReceipt]
        /// Restarts not yet finished, by refused task.
        var restarts: [RestartIntent]
        var state: State
    }

    /// An entry that exists but does not describe an event.
    struct UnreadableEntry: Error {
        let name: String
    }

    let storageRoot: URL
    let directory: URL

    init(storageRoot: URL, sessionIdentifier: String) {
        let name = String(sessionIdentifier.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return Character(scalar)
            default: return "_"
            }
        })
        self.storageRoot = storageRoot
        directory = storageRoot
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "_\(name)" : name, isDirectory: true)
    }

    static let directoryName = "transfer"

    var receipts: URL { directory.appendingPathComponent("receipts", isDirectory: true) }
    var events: URL { directory.appendingPathComponent("events", isDirectory: true) }
    var restarts: URL { directory.appendingPathComponent("restarts", isDirectory: true) }
    var stateFile: URL { directory.appendingPathComponent("state.json", isDirectory: false) }

    /// `url`, refused when it leaves the storage root or goes through a symbolic link.
    func confined(_ url: URL) throws -> URL {
        try PathConfinement.confined(url, within: storageRoot)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: try confined(receipts), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: try confined(events), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: try confined(restarts), withIntermediateDirectories: true)
        var parent = try confined(directory.deletingLastPathComponent())
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try parent.setResourceValues(values)
    }

    // MARK: Loading

    /// Reads every stored event, receipt and the reservation state. Throws when any of them
    /// cannot be read or decoded; never reports a partial inbox as complete.
    func load() throws -> Contents {
        let state = try readState()
        let stored: [StoredEvent] = try entries(in: events)
        for entry in stored where entry.event.event == nil { throw UnreadableEntry(name: "event \(entry.sequence)") }
        let pending: [CaptureReceipt] = try entries(in: receipts)
        for receipt in pending where receipt.event.event == nil { throw UnreadableEntry(name: "receipt \(receipt.id)") }
        let restarting: [RestartIntent] = try entries(in: restarts)
        return Contents(
            events: stored.sorted { $0.sequence < $1.sequence },
            receipts: pending.sorted { ($0.written, $0.id.uuidString) < ($1.written, $1.id.uuidString) },
            restarts: restarting.sorted { $0.taskIdentifier < $1.taskIdentifier },
            state: state
        )
    }

    private func entries<T: Decodable>(in directory: URL) throws -> [T] {
        let folder = try confined(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { name in
            let data = try Data(contentsOf: try confined(folder.appendingPathComponent(name, isDirectory: false)))
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw UnreadableEntry(name: name)
            }
        }
    }

    // MARK: Receipts

    func write(_ receipt: CaptureReceipt) throws {
        try Self.encoder.encode(receipt).write(to: try confined(receiptURL(receipt.id)), options: .atomic)
    }

    /// Deletes a receipt whose event is stored. Best effort: a leftover receipt whose event
    /// exists is only deleted on the next start.
    func removeReceipt(_ id: UUID) {
        guard let url = try? confined(receiptURL(id)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func receiptURL(_ id: UUID) -> URL {
        receipts.appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false)
    }

    // MARK: Events

    func write(_ event: StoredEvent) throws {
        try Self.encoder.encode(event).write(to: try confined(url(forSequence: event.sequence)), options: .atomic)
    }

    /// Deletes an acknowledged event. Best effort: a leftover is delivered again after a
    /// relaunch, and the manager applies a replay idempotently.
    func removeEvent(_ sequence: UInt64) {
        guard let url = try? confined(url(forSequence: sequence)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func url(forSequence sequence: UInt64) -> URL {
        let digits = String(sequence)
        return events.appendingPathComponent(String(repeating: "0", count: max(0, 20 - digits.count)) + digits + ".json", isDirectory: false)
    }

    // MARK: Restarts

    func write(_ restart: RestartIntent) throws {
        try Self.encoder.encode(restart).write(to: try confined(restartURL(restart.taskIdentifier)), options: .atomic)
    }

    /// Deletes a finished restart. Best effort: a leftover only suppresses the refused task's
    /// late completion once more.
    func removeRestart(_ taskIdentifier: Int) {
        guard let url = try? confined(restartURL(taskIdentifier)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func restartURL(_ taskIdentifier: Int) -> URL {
        restarts.appendingPathComponent("task-\(taskIdentifier).json", isDirectory: false)
    }

    // MARK: State

    /// The reservation state. Only a verified absence (never written) reads as zero.
    func readState() throws -> State {
        let url = try confined(stateFile)
        var status = stat()
        if lstat(url.path, &status) != 0 {
            let code = errno
            if code == ENOENT { return State(reservedSequence: 0) }
            throw DownloadFileSystemError(posixCode: code)
        }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder.decode(State.self, from: data)
        } catch {
            throw UnreadableEntry(name: "state.json")
        }
    }

    func write(_ state: State) throws {
        try Self.encoder.encode(state).write(to: try confined(stateFile), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
