//
//  TransferEvent.swift
//  DownloadKit
//

import Foundation

/// Identifies one system transfer task for one attempt of one item.
public struct TransferTaskReference: Hashable, Sendable {
    public let itemID: DownloadID
    public let generation: UInt64
    public let taskIdentifier: Int

    public init(itemID: DownloadID, generation: UInt64, taskIdentifier: Int) {
        self.itemID = itemID
        self.generation = generation
        self.taskIdentifier = taskIdentifier
    }

    /// Maps a task back to its item and attempt from the durable description written at
    /// submission (see ``TransferSubmission/taskDescription(sessionIdentifier:)``). Returns
    /// `nil` for any description this package did not write. The session named in the
    /// description is not checked; use ``init(taskDescription:taskIdentifier:sessionIdentifier:)``
    /// to refuse a task of another session.
    public init?(taskDescription: String?, taskIdentifier: Int) {
        guard let parsed = Self.parse(taskDescription) else { return nil }
        self.init(itemID: parsed.itemID, generation: parsed.generation, taskIdentifier: taskIdentifier)
    }

    /// Like ``init(taskDescription:taskIdentifier:)``, and also `nil` when the description names
    /// a session other than `sessionIdentifier`. A description written before the session was
    /// recorded in it (`downloadkit/1/...`) carries no session and is accepted: the system lists
    /// a task only for the session that owns it.
    public init?(taskDescription: String?, taskIdentifier: Int, sessionIdentifier: String) {
        guard let parsed = Self.parse(taskDescription) else { return nil }
        if let tag = parsed.sessionTag, tag != Self.sessionTag(sessionIdentifier) { return nil }
        self.init(itemID: parsed.itemID, generation: parsed.generation, taskIdentifier: taskIdentifier)
    }

    /// Format 1: `downloadkit/1/<generation>/<item>`. Format 2 adds the session:
    /// `downloadkit/2/<session tag>/<generation>/<item>`, where the tag is 16 lowercase
    /// hexadecimal digits of the FNV-1a 64-bit hash of the session identifier's UTF-8 bytes.
    /// The item identifier comes last because it may contain slashes.
    private static func parse(_ description: String?) -> (itemID: DownloadID, generation: UInt64, sessionTag: String?)? {
        guard let description else { return nil }
        var body: Substring
        var tag: String?
        if description.hasPrefix(descriptionPrefix) {
            body = description.dropFirst(descriptionPrefix.count)
        } else if description.hasPrefix(sessionDescriptionPrefix) {
            body = description.dropFirst(sessionDescriptionPrefix.count)
            guard let separator = body.firstIndex(of: "/") else { return nil }
            let candidate = String(body[body.startIndex..<separator])
            guard candidate.count == 16, candidate.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            tag = candidate
            body = body[body.index(after: separator)...]
        } else {
            return nil
        }
        guard let separator = body.firstIndex(of: "/"),
              let generation = UInt64(body[body.startIndex..<separator]),
              let itemID = try? DownloadID(String(body[body.index(after: separator)...])) else { return nil }
        return (itemID, generation, tag)
    }

    static let descriptionPrefix = "downloadkit/1/"
    static let sessionDescriptionPrefix = "downloadkit/2/"

    /// The format 1 description, without a session.
    static func taskDescription(itemID: DownloadID, generation: UInt64) -> String {
        "\(descriptionPrefix)\(generation)/\(itemID.rawValue)"
    }

    /// The format 2 description, naming the session.
    static func taskDescription(itemID: DownloadID, generation: UInt64, sessionIdentifier: String) -> String {
        "\(sessionDescriptionPrefix)\(sessionTag(sessionIdentifier))/\(generation)/\(itemID.rawValue)"
    }

    /// A stable, fixed-length tag for a session identifier (FNV-1a, 64 bits).
    static func sessionTag(_ sessionIdentifier: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sessionIdentifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// A task the system reports for a session, mapped or not.
public struct SystemTransferTask: Hashable, Sendable {
    public let taskIdentifier: Int
    /// The raw task description, exactly as the system returned it.
    public let taskDescription: String?

    public init(taskIdentifier: Int, taskDescription: String?) {
        self.taskIdentifier = taskIdentifier
        self.taskDescription = taskDescription
    }

    /// The item and attempt this task belongs to, or `nil` for a task the package did not
    /// create. Unmapped tasks are left alone, never adopted or cancelled. Does not check the
    /// session; see ``reference(inSession:)``.
    public var reference: TransferTaskReference? {
        TransferTaskReference(taskDescription: taskDescription, taskIdentifier: taskIdentifier)
    }

    /// The item and attempt this task belongs to in the session `sessionIdentifier`, or `nil`
    /// for a task the package did not create or whose description names another session.
    /// The manager reconciles with this: a task of another session is foreign and untouched.
    public func reference(inSession sessionIdentifier: String) -> TransferTaskReference? {
        TransferTaskReference(taskDescription: taskDescription, taskIdentifier: taskIdentifier, sessionIdentifier: sessionIdentifier)
    }
}

/// What the manager asks a ``TransferSession`` to start.
public struct TransferSubmission: Hashable, Sendable {
    public let itemID: DownloadID
    /// The attempt generation the session must echo in every event for this task.
    public let generation: UInt64
    /// The URL for this attempt. It may differ from the persisted source URL (see
    /// ``URLRefreshing/transferURL(for:sourceURL:metadata:)``).
    public let url: URL
    /// The effective policy, applied per request before the task is created.
    public let policy: NetworkPolicy
    /// Resume data captured from an earlier attempt. The session owns it from here on and may
    /// discard it when the server no longer accepts it (safe restart, never a blind append).
    public let resumeDataPath: RelativePath?
    public let expectedLength: Int64?

    public init(itemID: DownloadID, generation: UInt64, url: URL, policy: NetworkPolicy, resumeDataPath: RelativePath?, expectedLength: Int64?) {
        self.itemID = itemID
        self.generation = generation
        self.url = url
        self.policy = policy
        self.resumeDataPath = resumeDataPath
        self.expectedLength = expectedLength
    }

    /// The durable description without a session (format 1). Prefer
    /// ``taskDescription(sessionIdentifier:)``; this form is still accepted for any session.
    public var taskDescription: String {
        TransferTaskReference.taskDescription(itemID: itemID, generation: generation)
    }

    /// The durable description the session sets on the task before resuming it: item,
    /// generation and the session's identity, so the task can be mapped back to its item and
    /// attempt after a relaunch even when the binding was never written, and a task listed
    /// under another session is never adopted. Parse it with
    /// ``TransferTaskReference/init(taskDescription:taskIdentifier:sessionIdentifier:)``.
    public func taskDescription(sessionIdentifier: String) -> String {
        TransferTaskReference.taskDescription(itemID: itemID, generation: generation, sessionIdentifier: sessionIdentifier)
    }

    func with(url: URL) -> TransferSubmission {
        TransferSubmission(itemID: itemID, generation: generation, url: url, policy: policy, resumeDataPath: resumeDataPath, expectedLength: expectedLength)
    }
}

/// A typed, immutable event from a transfer session.
///
/// Every event carries the attempt generation; events whose generation no longer matches the
/// record are ignored, and a file they reference is discarded only when no record owns it.
public enum TransferEvent: Hashable, Sendable {
    case progress(TransferTaskReference, bytesWritten: Int64, expectedBytes: Int64?)
    case waiting(TransferTaskReference, WaitReason)
    /// The downloaded file was already moved into package-owned staging before the system
    /// callback returned.
    ///
    /// Adapter prerequisite: the session sends `finished` only for a response it accepted as
    /// usable media: a 2xx status consistent with the request (a 206 only for a range it
    /// asked for, never a 200 appended to partial bytes) and not an error page. Anything else
    /// is reported as ``failed(_:_:)``. The validators recorded here are the evidence kept
    /// with the capture for finalisation and later resumption.
    case finished(TransferTaskReference, captured: RelativePath, bytes: Int64, validators: ResponseValidators?)
    case failed(TransferTaskReference, TransferFailure)
    case resumeDataCaptured(TransferTaskReference, RelativePath)

    /// Whether losing this event would lose state. Progress and waiting are advisory.
    var isTerminal: Bool {
        switch self {
        case .progress, .waiting: return false
        case .finished, .failed, .resumeDataCaptured: return true
        }
    }
}

/// One entry of a session's ordered event stream.
public struct TransferSessionEvent: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        /// A task event.
        case transfer(TransferEvent)
        /// Every event pending when the session was created or reconnected has been delivered.
        /// Only after this marker does the manager decide that an expected task is gone.
        case backlogDelivered
        /// The system finished delivering the events of a background wake. When the manager
        /// has applied everything before this marker, it calls the host's completion handlers
        /// accepted before the marker was reported (``BackgroundTransferEvents``).
        case backgroundEventsFinished
        /// The session could not read or store its durable backlog (an unreadable inbox, or a
        /// terminal event or sequence reservation it could not write), so it withholds
        /// ``backlogDelivered``. The manager reports reconciliation unresolved with
        /// ``ReconciliationUnresolvedReason/sessionStorageFailed`` and concludes nothing; the
        /// marker follows once the session recovered. It is not a new position in the stream:
        /// its sequence repeats the last one delivered (0 when nothing was), and acknowledging it
        /// releases nothing new.
        case backlogUnavailable
    }

    /// Strictly increasing per session across events and the two markers (except
    /// ``Payload/backlogUnavailable``, which repeats the last number); acknowledged with
    /// ``TransferSession/acknowledge(through:)``.
    public let sequence: UInt64
    public let payload: Payload
    /// Where a ``Payload/backgroundEventsFinished`` marker stands among the host's accepted
    /// wake handlers: it releases only those accepted before it. Not part of the event's
    /// identity.
    let wakeOrder: UInt64

    /// A ``Payload/backgroundEventsFinished`` marker is placed after every wake handler accepted
    /// so far: create it when the system reports the wake drained, not later.
    public init(sequence: UInt64, payload: Payload) {
        self.init(sequence: sequence, payload: payload, wakeOrder: payload == .backgroundEventsFinished ? WakeOrder.next() : 0)
    }

    init(sequence: UInt64, payload: Payload, wakeOrder: UInt64) {
        self.sequence = sequence
        self.payload = payload
        self.wakeOrder = wakeOrder
    }

    public static func == (lhs: TransferSessionEvent, rhs: TransferSessionEvent) -> Bool {
        lhs.sequence == rhs.sequence && lhs.payload == rhs.payload
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
        hasher.combine(payload)
    }
}
