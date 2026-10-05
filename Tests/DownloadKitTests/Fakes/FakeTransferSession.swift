import Foundation
@testable import DownloadKit

/// A transfer session driven entirely by the test.
///
/// Live tasks carry the durable description the manager asked for, so reconciliation maps
/// them exactly as it would map system tasks. Events are sequence-numbered; a backlog given
/// at creation is delivered first, followed by the backlog marker unless the session is told
/// to withhold it (a compliant session whose marker is late).
actor FakeTransferSession: TransferSession {
    struct Cancellation: Equatable {
        let taskIdentifier: Int
        let producingResumeData: Bool
    }

    nonisolated let identifier: String
    nonisolated let events: AsyncStream<TransferSessionEvent>
    private nonisolated let continuation: AsyncStream<TransferSessionEvent>.Continuation

    private(set) var submissions: [TransferSubmission] = []
    private(set) var cancellations: [Cancellation] = []
    private(set) var liveTasks: [TransferTaskReference] = []
    private(set) var unmappedTasks: [SystemTransferTask] = []
    private(set) var acknowledged: UInt64?
    private var nextTaskIdentifier = 100
    private var nextSequence: UInt64 = 0
    private var submitFailure: TransferFailure?
    private let log: CallLog?

    init(
        identifier: String,
        liveTasks: [TransferTaskReference] = [],
        unmappedTasks: [SystemTransferTask] = [],
        backlog: [TransferEvent] = [],
        deliversBacklogMarker: Bool = true,
        log: CallLog? = nil
    ) {
        self.identifier = identifier
        self.liveTasks = liveTasks
        self.unmappedTasks = unmappedTasks
        self.log = log
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSessionEvent.self)
        self.events = stream
        self.continuation = continuation
        var sequence: UInt64 = 0
        for event in backlog {
            sequence += 1
            continuation.yield(TransferSessionEvent(sequence: sequence, payload: .transfer(event)))
        }
        if deliversBacklogMarker {
            sequence += 1
            continuation.yield(TransferSessionEvent(sequence: sequence, payload: .backlogDelivered))
        }
        self.nextSequence = sequence
    }

    /// Adds a task the system reports (for example one whose number was reused).
    func addSystemTask(_ task: TransferTaskReference) {
        liveTasks.append(task)
    }

    func setSubmitFailure(_ failure: TransferFailure?) {
        submitFailure = failure
    }

    func submit(_ submission: TransferSubmission) async throws -> Int {
        await log?.append("submit \(submission.itemID.rawValue) g\(submission.generation)")
        if let submitFailure { throw submitFailure }
        nextTaskIdentifier += 1
        submissions.append(submission)
        liveTasks.append(TransferTaskReference(itemID: submission.itemID, generation: submission.generation, taskIdentifier: nextTaskIdentifier))
        return nextTaskIdentifier
    }

    func cancel(taskIdentifier: Int, producingResumeData: Bool) async {
        await log?.append("cancel \(taskIdentifier)")
        cancellations.append(Cancellation(taskIdentifier: taskIdentifier, producingResumeData: producingResumeData))
        liveTasks.removeAll { $0.taskIdentifier == taskIdentifier }
    }

    func systemTasks() -> [SystemTransferTask] {
        liveTasks.map {
            SystemTransferTask(taskIdentifier: $0.taskIdentifier, taskDescription: TransferTaskReference.taskDescription(itemID: $0.itemID, generation: $0.generation))
        } + unmappedTasks
    }

    func acknowledge(through sequence: UInt64) {
        acknowledged = sequence
    }

    /// The reference of the most recent submission for `id`.
    func latestReference(for id: DownloadID) -> TransferTaskReference? {
        liveTasks.last { $0.itemID == id }
    }

    /// Emits one task event and returns its sequence number.
    @discardableResult
    func emit(_ event: TransferEvent) -> UInt64 {
        emit(payload: .transfer(event))
    }

    @discardableResult
    func emit(payload: TransferSessionEvent.Payload) -> UInt64 {
        nextSequence += 1
        continuation.yield(TransferSessionEvent(sequence: nextSequence, payload: payload))
        return nextSequence
    }
}

/// Hands out one prepared session.
struct FakeTransferSessionFactory: TransferSessionFactory {
    let session: FakeTransferSession
    var fails = false

    func makeSession(identifier: String, storageRoot: URL) async throws -> any TransferSession {
        if fails { throw FakeError.injected }
        return session
    }
}
