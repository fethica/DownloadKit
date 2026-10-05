//
//  URLSessionTransportTests.swift
//  DownloadKitTests
//
//  The foreground adapter against the URLProtocol fixture: one test per response scenario,
//  plus durable replay, foreign tasks and resume fallbacks.
//

import Foundation
import XCTest
@testable import DownloadKit

final class URLSessionTransportTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var transports: [URLSessionTransport] = []

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("transport")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for transport in transports { await transport.invalidate(cancellingTasks: true) }
        transports = []
        directory.remove()
    }

    private var root: URL { directory.url }

    private func makeTransport() -> URLSessionTransport {
        let transport = URLSessionTransport.stubbed()
        transports.append(transport)
        return transport
    }

    private func submission(_ path: String, size: Int = 4_096, item: String = "episode", generation: UInt64 = 1, resume: RelativePath? = nil, policy: NetworkPolicy = .default) -> TransferSubmission {
        TransferSubmission(itemID: itemID(item), generation: generation, url: StubRoute.url(path, size: size), policy: policy, resumeDataPath: resume, expectedLength: nil)
    }

    /// Runs one submission to its terminal event.
    private func run(_ path: String, size: Int = 4_096, transport: URLSessionTransport? = nil, identifier: String = Harness.uniqueName("session")) async throws -> (event: TransferEvent?, recorder: EventRecorder, session: any TransferSession) {
        let session = try await (transport ?? makeTransport()).makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = try await session.submit(submission(path, size: size))
        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished, "no terminal event for \(path)")
        return (await recorder.terminalEvents.first, recorder, session)
    }

    private func failure(_ event: TransferEvent?) -> TransferFailure? {
        if case .failed(_, let failure) = event { return failure }
        return nil
    }

    private func stagingEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path)
    }

    // MARK: Success

    func testCompletedDownloadIsCapturedBeforeItIsDelivered() async throws {
        let size = 300_000
        let (event, recorder, session) = try await run("/ok", size: size)
        guard case .finished(let reference, let captured, let bytes, let validators) = event else {
            return XCTFail("expected a finished event, got \(String(describing: event))")
        }
        XCTAssertEqual(reference.itemID, itemID("episode"))
        XCTAssertEqual(reference.generation, 1)
        XCTAssertEqual(bytes, Int64(size))
        XCTAssertEqual(validators, ResponseValidators(entityTag: "\"v1\"", lastModified: "Mon, 05 Oct 2026 10:00:00 GMT", statusCode: 200, mediaType: "audio/mpeg"))
        XCTAssertTrue(captured.rawValue.hasPrefix("staging/"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(captured.rawValue)), StubRoute.body(size: size))

        let progress = await recorder.transferEvents.compactMap { event -> Int64? in
            if case .progress(_, let written, let expected) = event {
                XCTAssertEqual(expected, Int64(size))
                return written
            }
            return nil
        }
        XCTAssertFalse(progress.isEmpty)
        XCTAssertEqual(progress, progress.sorted())

        // Stored before delivery, released by the acknowledgement.
        let host = try await XCTUnwrapAsync(await transports[0].host(for: session.identifier))
        let recorded = await recorder.events
        let terminalSequence = try XCTUnwrap(recorded.first { if case .transfer(let e) = $0.payload { return e.isTerminal } else { return false } }?.sequence)
        let pending = await host.unacknowledgedSequences
        XCTAssertEqual(pending, [terminalSequence])
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: session.identifier)
        XCTAssertEqual(inbox.storedEvents().map(\.sequence), [terminalSequence])
        XCTAssertTrue(inbox.pendingReceipts().isEmpty, "the receipt became an event")
        await session.acknowledge(through: terminalSequence)
        XCTAssertTrue(inbox.storedEvents().isEmpty)

        let sequences = await recorder.events.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
    }

    func testRedirectIsFollowed() async throws {
        let (event, _, _) = try await run("/redirect", size: 2_048)
        guard case .finished(_, _, let bytes, _) = event else { return XCTFail("\(String(describing: event))") }
        XCTAssertEqual(bytes, 2_048)
    }

    func testMissingLengthReportsIndeterminateProgressAndCompletes() async throws {
        let (event, recorder, _) = try await run("/no-length", size: 200_000)
        guard case .finished(_, _, let bytes, _) = event else { return XCTFail("\(String(describing: event))") }
        XCTAssertEqual(bytes, 200_000)
        let expectations = await recorder.transferEvents.compactMap { event -> Int64?? in
            if case .progress(_, _, let expected) = event { return .some(expected) }
            return nil
        }
        XCTAssertFalse(expectations.isEmpty)
        XCTAssertTrue(expectations.allSatisfy { $0 == nil }, "unknown size is indeterminate")
    }

    func testSlowFirstByteKeepsTheTaskRunningUntilBytesArrive() async throws {
        let session = try await makeTransport().makeSession(identifier: Harness.uniqueName("session"), storageRoot: root)
        let recorder = EventRecorder.record(session)
        let taskIdentifier = try await session.submit(submission("/slow", size: 1_024))
        await realTimeEventually("the slow request arrived") { slowRequestHasArrived() }

        let tasks = await session.systemTasks()
        XCTAssertTrue(tasks.contains { $0.taskIdentifier == taskIdentifier && $0.reference?.itemID == itemID("episode") })
        let early = await recorder.terminalEvents
        XCTAssertTrue(early.isEmpty, "nothing terminal before the first byte")

        slowFirstByteGate.signal()
        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished)
        guard case .finished = await recorder.terminalEvents.first else { return XCTFail("slow route did not finish") }
    }

    // MARK: Failures

    func testMidTransferDisconnectIsTransientAndCapturesNothing() async throws {
        let (event, _, _) = try await run("/disconnect", size: 200_000)
        let failure = try XCTUnwrap(self.failure(event))
        XCTAssertEqual(failure.classification, .networkTransient)
        XCTAssertEqual(try stagingEntries(), [])
    }

    func testTruncatedBodyIsTransientAndCapturesNothing() async throws {
        let (event, _, _) = try await run("/truncated", size: 200_000)
        XCTAssertEqual(failure(event), .network(code: URLError.networkConnectionLost.rawValue))
        XCTAssertEqual(try stagingEntries(), [])
    }

    func testNotFoundIsPermanent() async throws {
        let (event, _, _) = try await run("/missing")
        XCTAssertEqual(failure(event), .http(status: 404, retryAfter: nil))
        XCTAssertEqual(failure(event)?.classification, .permanentHTTP)
        XCTAssertEqual(try stagingEntries(), [])
    }

    func testServerErrorsCarryRetryAfter() async throws {
        let transport = makeTransport()
        let (unavailable, _, _) = try await run("/unavailable", transport: transport)
        XCTAssertEqual(failure(unavailable), .http(status: 503, retryAfter: 120))
        XCTAssertEqual(failure(unavailable)?.classification, .networkTransient)
        let (error, _, _) = try await run("/error", transport: transport)
        XCTAssertEqual(failure(error), .http(status: 500, retryAfter: 7))
    }

    func testHTMLServedAsSuccessIsRejected() async throws {
        let transport = makeTransport()
        let (declared, _, _) = try await run("/html", transport: transport)
        XCTAssertEqual(failure(declared), .invalidResponse)
        let (sniffed, _, _) = try await run("/html-as-audio", transport: transport)
        XCTAssertEqual(failure(sniffed), .invalidResponse)
        XCTAssertEqual(try stagingEntries(), [])
    }

    func testExpiredOrUnauthorizedURLIsAnAuthenticationFailure() async throws {
        let transport = makeTransport()
        let (expired, _, _) = try await run("/expired", transport: transport)
        XCTAssertEqual(failure(expired)?.classification, .authentication)
        XCTAssertEqual(failure(expired)?.downloadFailure.kind, .unauthorized)
        let (unauthorized, _, _) = try await run("/unauthorized", transport: transport)
        XCTAssertEqual(failure(unauthorized), .http(status: 401, retryAfter: nil))
    }

    func testUnsolicitedPartialContentIsRejected() async throws {
        let (event, _, _) = try await run("/partial")
        XCTAssertEqual(failure(event), .invalidResponse)
        XCTAssertEqual(try stagingEntries(), [])
    }

    func testRangeNotSatisfiableWithoutARangeIsAnHTTPFailure() async throws {
        let (event, _, _) = try await run("/range-not-satisfiable")
        XCTAssertEqual(failure(event), .http(status: 416, retryAfter: nil))
    }

    // MARK: Resume and restart

    func testUnusableResumeDataFallsBackToAFreshRequest() async throws {
        let resume = path("staging/resume-garbage")
        try writeFile(root.appendingPathComponent(resume.rawValue), Data("not a property list".utf8))
        let session = try await makeTransport().makeSession(identifier: Harness.uniqueName("session"), storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = try await session.submit(submission("/ok", size: 10_000, resume: resume))
        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished)
        guard case .finished(_, _, let bytes, _) = await recorder.terminalEvents.first else { return XCTFail("no completion") }
        XCTAssertEqual(bytes, 10_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(resume.rawValue).path), "the session consumed the resume data")
        XCTAssertFalse(TransferSessionHost.isUsableResumeData(Data()))
        XCTAssertTrue(TransferSessionHost.isUsableResumeData(try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .binary, options: 0)))
    }

    func testRefusedContinuationRestartsFromZeroUnderTheSameIdentity() async throws {
        let transport = makeTransport()
        let session = try await transport.makeSession(identifier: Harness.uniqueName("session"), storageRoot: root)
        let recorder = EventRecorder.record(session)
        let original = try await session.submit(submission("/slow", size: 4_096))
        await realTimeEventually("the first request arrived") { slowRequestHasArrived() }
        let host = try await XCTUnwrapAsync(await transport.host(for: session.identifier))

        // The server answered the continuation with 416: the adapter starts again from zero.
        await host.inject(.restart(taskIdentifier: original, description: submission("/slow").taskDescription))
        slowFirstByteGate.signal()
        await realTimeEventually("the replacement request arrived") { slowRequestHasArrived() }
        slowFirstByteGate.signal()

        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished)
        let terminal = await recorder.terminalEvents
        XCTAssertEqual(terminal.count, 1, "the replaced task reports nothing")
        guard case .finished(let reference, _, _, _) = terminal.first else { return XCTFail("\(terminal)") }
        XCTAssertEqual(reference.generation, 1)
        XCTAssertNotEqual(reference.taskIdentifier, original)
    }

    func testPolicyIsAppliedToEachRequest() {
        let deferred = NetworkPolicy(allowsCellular: false, allowsExpensive: true, allowsConstrained: false, scheduling: .deferred)
        let request = TransferSessionHost.request(for: submission("/ok", policy: deferred))
        XCTAssertFalse(request.allowsCellularAccess)
        XCTAssertTrue(request.allowsExpensiveNetworkAccess)
        XCTAssertFalse(request.allowsConstrainedNetworkAccess)
        XCTAssertEqual(request.networkServiceType, .background)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let configuration = URLSessionTransport.Options().makeConfiguration(identifier: "x")
        XCTAssertFalse(configuration.allowsCellularAccess, "the session default never widens the item default")
        XCTAssertNil(configuration.urlCache)
    }

    // MARK: Durable replay

    func testUnacknowledgedEventsAreReplayedWithTheirSequenceNumbersAfterARelaunch() async throws {
        let identifier = Harness.uniqueName("session")
        let (event, recorder, _) = try await run("/ok", size: 5_000, identifier: identifier)
        let recorded = await recorder.events
        let original = try XCTUnwrap(recorded.first { $0.payload == .transfer(event!) })

        // A new transport over the same root stands for a relaunch: same identifier, new process.
        let relaunched = try await makeTransport().makeSession(identifier: identifier, storageRoot: root)
        let replay = EventRecorder.record(relaunched)
        let delivered = await replay.wait { $0.hasBacklogMarker }
        XCTAssertTrue(delivered)
        let replayed = await replay.events
        XCTAssertEqual(replayed.first, original, "same event, same sequence number")
        let marker = try XCTUnwrap(replayed.first { $0.payload == .backlogDelivered })
        XCTAssertGreaterThan(marker.sequence, original.sequence)
        let liveSequences = await recorder.events.map(\.sequence)
        XCTAssertGreaterThan(marker.sequence, liveSequences.max() ?? 0, "numbers are never reused across launches")

        await relaunched.acknowledge(through: original.sequence)
        let third = try await makeTransport().makeSession(identifier: identifier, storageRoot: root)
        let after = EventRecorder.record(third)
        _ = await after.wait { $0.hasBacklogMarker }
        let remaining = await after.events
        XCTAssertEqual(remaining.terminalCount, 0, "an acknowledged event is never delivered again")
    }

    func testNextSessionObjectReplaysUnacknowledgedEvents() async throws {
        let transport = makeTransport()
        let identifier = Harness.uniqueName("session")
        let (event, recorder, _) = try await run("/ok", size: 5_000, transport: transport, identifier: identifier)
        let recorded = await recorder.events
        let original = try XCTUnwrap(recorded.first { $0.payload == .transfer(event!) })

        let successor = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let replay = EventRecorder.record(successor)
        _ = await replay.wait { $0.hasBacklogMarker }
        let replayed = await replay.events
        XCTAssertEqual(replayed.first, original)
    }

    func testReceiptWrittenBeforeACrashIsDeliveredExactlyOnce() async throws {
        let identifier = Harness.uniqueName("session")
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
        try inbox.prepare()
        try writeFile(root.appendingPathComponent("staging/captured-a"), mediaBytes(100))
        let reference = TransferTaskReference(itemID: itemID("a"), generation: 4, taskIdentifier: 9)
        let lost = CaptureReceipt(id: UUID(), written: referenceDate, event: StoredTransferEvent(.finished(reference, captured: path("staging/captured-a"), bytes: 100, validators: nil))!)
        try inbox.write(lost)
        // A receipt whose event was already stored: the process ended before deleting it.
        let stored = CaptureReceipt(id: UUID(), written: referenceDate, event: StoredTransferEvent(.failed(TransferTaskReference(itemID: itemID("b"), generation: 2, taskIdentifier: 3), .cancelled))!)
        try inbox.write(stored)
        try inbox.write(StoredEvent(sequence: 40, receipt: stored.id, event: stored.event))
        try inbox.write(TransferInbox.State(reservedSequence: 50))

        let session = try await makeTransport().makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = await recorder.wait { $0.hasBacklogMarker }
        let events = await recorder.events
        XCTAssertEqual(events.terminalCount, 2)
        XCTAssertEqual(events.first?.sequence, 40)
        XCTAssertEqual(events.first?.payload, .transfer(.failed(TransferTaskReference(itemID: itemID("b"), generation: 2, taskIdentifier: 3), .cancelled)))
        XCTAssertEqual(events[1].payload, .transfer(.finished(reference, captured: path("staging/captured-a"), bytes: 100, validators: nil)))
        XCTAssertGreaterThan(events[1].sequence, 50, "a reserved number is never reused")
        XCTAssertTrue(inbox.pendingReceipts().isEmpty)
        XCTAssertEqual(inbox.storedEvents().count, 2)
    }

    // MARK: Foreign tasks

    func testForeignTasksAreListedAndNeverTouched() async throws {
        let transport = makeTransport()
        let session = try await transport.makeSession(identifier: Harness.uniqueName("session"), storageRoot: root)
        let recorder = EventRecorder.record(session)
        let host = try await XCTUnwrapAsync(await transport.host(for: session.identifier))
        let urlSession = await host.urlSession

        // A task another library created on the same session, held before its first byte.
        let foreign = urlSession.downloadTask(with: StubRoute.url("/slow", size: 8_000))
        foreign.taskDescription = "another-library/7"
        foreign.resume()
        await realTimeEventually("the foreign request arrived") { slowRequestHasArrived() }

        let tasks = await session.systemTasks()
        let listed = try XCTUnwrap(tasks.first { $0.taskIdentifier == foreign.taskIdentifier })
        XCTAssertNil(listed.reference)
        XCTAssertEqual(listed.taskDescription, "another-library/7")

        await session.cancel(taskIdentifier: foreign.taskIdentifier, producingResumeData: true)
        XCTAssertEqual(foreign.state, .running, "a foreign task is never cancelled")
        slowFirstByteGate.signal()
        await realTimeEventually("the foreign task completed") { foreign.state == .completed }

        // The foreign completion was seen and ignored: nothing captured, nothing reported.
        _ = try await session.submit(submission("/ok", size: 1_000))
        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished)
        let terminal = await recorder.terminalEvents
        XCTAssertEqual(terminal.count, 1)
        XCTAssertEqual(try stagingEntries().count, 1, "only the package's own file was captured")
    }
}

/// Polls `condition` every millisecond of real time, for conditions that depend on URLSession's
/// own threads, and fails after `timeout` seconds.
func realTimeEventually(_ message: String = "", timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition never held: \(message)", file: file, line: line)
}
