import Foundation
@testable import DownloadKit

/// A transfer session driven entirely by the test.
actor FakeTransferSession: TransferSession {
    struct Cancellation: Equatable {
        let taskIdentifier: Int
        let producingResumeData: Bool
    }

    nonisolated let identifier: String
    nonisolated let events: AsyncStream<TransferEvent>
    private nonisolated let continuation: AsyncStream<TransferEvent>.Continuation

    private(set) var submissions: [TransferSubmission] = []
    private(set) var cancellations: [Cancellation] = []
    private(set) var liveTasks: [TransferTaskReference] = []
    private var nextTaskIdentifier = 100
    private var submitFailure: TransferFailure?
    private let log: CallLog?

    init(identifier: String, liveTasks: [TransferTaskReference] = [], log: CallLog? = nil) {
        self.identifier = identifier
        self.liveTasks = liveTasks
        self.log = log
        let (stream, continuation) = AsyncStream.makeStream(of: TransferEvent.self)
        self.events = stream
        self.continuation = continuation
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

    func activeTasks() -> [TransferTaskReference] {
        liveTasks
    }

    /// The reference of the most recent submission for `id`.
    func latestReference(for id: DownloadID) -> TransferTaskReference? {
        liveTasks.last { $0.itemID == id }
    }

    nonisolated func emit(_ event: TransferEvent) {
        continuation.yield(event)
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
