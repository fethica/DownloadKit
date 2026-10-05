//
//  TransferInbox.swift
//  DownloadKit
//
//  The adapter's durable record of terminal events, on disk under
//  `<root>/transfer/<session>/`:
//  - `receipts/`: one file per terminal outcome, written synchronously inside the system
//    callback right after the downloaded file was moved into `staging/`, before the callback
//    returns. A receipt has no sequence number yet.
//  - `events/`: one file per sequenced terminal event, written before the event is delivered.
//    A file is deleted once the manager acknowledged its sequence number.
//  - `state.json`: the highest reserved sequence number, so numbers are never reused across
//    launches.
//
//  Crash windows: a receipt without an event becomes an event on the next start; a receipt
//  whose event exists (the process ended between writing the event and deleting the receipt)
//  is only deleted. No URL, header or credential is ever written here.
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

/// One sequenced terminal event.
struct StoredEvent: Codable, Hashable, Sendable {
    let sequence: UInt64
    /// The receipt this event was made from, when there was one.
    let receipt: UUID?
    let event: StoredTransferEvent
}

/// The files of one session's inbox. Every operation is synchronous and small.
struct TransferInbox: Sendable {
    struct State: Codable, Hashable, Sendable {
        var reservedSequence: UInt64
    }

    let directory: URL

    init(storageRoot: URL, sessionIdentifier: String) {
        let name = String(sessionIdentifier.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return Character(scalar)
            default: return "_"
            }
        })
        directory = storageRoot
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "_\(name)" : name, isDirectory: true)
    }

    static let directoryName = "transfer"

    var receipts: URL { directory.appendingPathComponent("receipts", isDirectory: true) }
    var events: URL { directory.appendingPathComponent("events", isDirectory: true) }
    var stateFile: URL { directory.appendingPathComponent("state.json", isDirectory: false) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        var parent = directory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? parent.setResourceValues(values)
    }

    // MARK: Receipts

    func write(_ receipt: CaptureReceipt) throws {
        let url = receipts.appendingPathComponent("\(receipt.id.uuidString.lowercased()).json", isDirectory: false)
        try Self.encoder.encode(receipt).write(to: url, options: .atomic)
    }

    /// Receipts on disk, oldest first. Files that do not decode are left alone.
    func pendingReceipts() -> [CaptureReceipt] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: receipts.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: receipts.appendingPathComponent(name)) else { return nil }
            return try? Self.decoder.decode(CaptureReceipt.self, from: data)
        }.sorted { ($0.written, $0.id.uuidString) < ($1.written, $1.id.uuidString) }
    }

    func removeReceipt(_ id: UUID) {
        try? FileManager.default.removeItem(at: receipts.appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false))
    }

    // MARK: Events

    func write(_ event: StoredEvent) throws {
        try Self.encoder.encode(event).write(to: url(forSequence: event.sequence), options: .atomic)
    }

    /// Stored events, in sequence order. Files that do not decode are left alone.
    func storedEvents() -> [StoredEvent] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: events.appendingPathComponent(name)) else { return nil }
            return try? Self.decoder.decode(StoredEvent.self, from: data)
        }.sorted { $0.sequence < $1.sequence }
    }

    func removeEvent(_ sequence: UInt64) {
        try? FileManager.default.removeItem(at: url(forSequence: sequence))
    }

    private func url(forSequence sequence: UInt64) -> URL {
        let digits = String(sequence)
        return events.appendingPathComponent(String(repeating: "0", count: max(0, 20 - digits.count)) + digits + ".json", isDirectory: false)
    }

    // MARK: State

    func readState() -> State {
        guard let data = try? Data(contentsOf: stateFile), let state = try? Self.decoder.decode(State.self, from: data) else {
            return State(reservedSequence: 0)
        }
        return state
    }

    func write(_ state: State) throws {
        try Self.encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
