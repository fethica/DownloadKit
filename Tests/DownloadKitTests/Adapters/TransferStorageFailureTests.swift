//
//  TransferStorageFailureTests.swift
//  DownloadKitTests
//
//  The transfer adapter when its durable inbox cannot be written or read: independent faults on
//  the receipt, event and sequence reservation writes, unreadable or corrupt entries, a relaunch
//  in between, the delegate-queue barrier behind the backlog marker, and symbolic links in place
//  of the adapter's directories and files. Faults are real file permissions on the real file
//  system, so each one interrupts the production pipeline between its steps.
//

import Foundation
import XCTest
@testable import DownloadKit

final class TransferStorageFailureTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var transports: [URLSessionTransport] = []

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("transfer-storage")
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

    private func submission(_ path: String, size: Int = 4_096, item: String = "episode", generation: UInt64 = 1, resume: RelativePath? = nil) -> TransferSubmission {
        TransferSubmission(itemID: itemID(item), generation: generation, url: StubRoute.url(path, size: size), policy: .default, resumeDataPath: resume, expectedLength: nil)
    }

    private func setPermissions(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func entries(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func isUnavailable(_ event: TransferSessionEvent) -> Bool { event.payload == .backlogUnavailable }

    // MARK: Event write

    func testFailedEventWriteKeepsTheReceiptWithholdsTheMarkerAndDeliversOnceAfterARelaunch() async throws {
        let identifier = Harness.uniqueName("session")
        let transport = makeTransport()
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = await recorder.wait { $0.hasBacklogMarker }
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)

        // Events cannot be written; receipts and the reservation still can.
        try setPermissions(0o500, inbox.events)
        _ = try await session.submit(submission("/ok", size: 3_000))
        await realTimeEventually("the outcome is pending") { await host.pendingCount == 1 }

        let receipts = entries(inbox.receipts)
        XCTAssertEqual(receipts.count, 1, "the receipt is the durable association and is kept")
        XCTAssertEqual(entries(root.appendingPathComponent("staging")).count, 1, "the capture stays")
        let delivered = await recorder.terminalEvents
        XCTAssertTrue(delivered.isEmpty, "nothing is delivered from memory alone")

        // A reconnecting manager is told the backlog is unavailable, never that it was delivered.
        let reconnected = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let second = EventRecorder.record(reconnected)
        let told = await second.wait { $0.contains { $0.payload == .backlogUnavailable } }
        XCTAssertTrue(told)
        let early = await second.events
        XCTAssertFalse(early.hasBacklogMarker)

        // The process ends here. The next launch reads the receipt while events are still
        // unwritable, then storage recovers.
        await transport.invalidate(cancellingTasks: true)
        let relaunch = makeTransport()
        let afterRelaunch = try await relaunch.makeSession(identifier: identifier, storageRoot: root)
        let third = EventRecorder.record(afterRelaunch)
        _ = await third.wait { $0.contains { $0.payload == .backlogUnavailable } }
        let relaunchedHost = try await XCTUnwrapAsync(await relaunch.host(for: identifier))
        let pendingAfterRelaunch = await relaunchedHost.pendingCount
        XCTAssertEqual(pendingAfterRelaunch, 1)
        XCTAssertEqual(entries(inbox.receipts), receipts)

        try setPermissions(0o755, inbox.events)
        await relaunchedHost.retryStorage()
        let recovered = await third.wait { $0.hasBacklogMarker }
        XCTAssertTrue(recovered)
        let events = await third.events
        let finished = try XCTUnwrap(events.first { if case .transfer(let event) = $0.payload { return event.isTerminal } else { return false } })
        let marker = try XCTUnwrap(events.first { $0.payload == .backlogDelivered })
        XCTAssertEqual(events.terminalCount, 1, "delivered exactly once")
        XCTAssertLessThan(finished.sequence, marker.sequence, "the marker follows the recovered event")
        XCTAssertEqual(entries(inbox.receipts), [], "the receipt goes only once its event is stored")
        XCTAssertEqual(inbox.storedEvents().map(\.sequence), [finished.sequence])
        await afterRelaunch.acknowledge(through: marker.sequence)
        XCTAssertEqual(inbox.storedEvents(), [])
    }

    // MARK: Reservation write

    func testFailedReservationDeliversNothingUntilANumberIsReserved() async throws {
        let identifier = Harness.uniqueName("session")
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
        try inbox.prepare()
        // The session directory (where the reservation lives) is read-only; receipts and events
        // are writable.
        try setPermissions(0o500, inbox.directory)

        let transport = makeTransport()
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        let told = await recorder.wait { $0.contains { $0.payload == .backlogUnavailable } }
        XCTAssertTrue(told, "no marker without a reserved number")
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))

        _ = try await session.submit(submission("/ok", size: 2_000))
        await realTimeEventually("the outcome is pending") { await host.pendingCount == 1 }
        XCTAssertEqual(entries(inbox.receipts).count, 1)
        XCTAssertEqual(entries(inbox.events), [])
        let nothing = await recorder.terminalEvents
        XCTAssertTrue(nothing.isEmpty)

        try setPermissions(0o755, inbox.directory)
        await host.retryStorage()
        let delivered = await recorder.wait { $0.hasBacklogMarker && $0.terminalCount == 1 }
        XCTAssertTrue(delivered)
        let events = await recorder.events.filter { !isUnavailable($0) }
        let sequences = events.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
        XCTAssertEqual(try inbox.readState().reservedSequence, 256, "the number used was reserved first")
    }

    // MARK: Receipt write

    func testReceiptThatCannotBeWrittenMovesNothingAndFailsAsStorage() async throws {
        let identifier = Harness.uniqueName("session")
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
        try inbox.prepare()
        try setPermissions(0o500, inbox.receipts)

        let session = try await makeTransport().makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = try await session.submit(submission("/ok", size: 2_000))
        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished)

        let terminal = await recorder.terminalEvents
        guard case .failed(_, let failure) = terminal.first else { return XCTFail("\(terminal)") }
        XCTAssertEqual(failure, .storage(.permissionDenied), "no capture is claimed without its association")
        XCTAssertEqual(entries(root.appendingPathComponent("staging")), [], "nothing was moved")
        XCTAssertEqual(inbox.storedEvents().count, 1, "the failure itself is stored")
    }

    // MARK: Unreadable backlog

    func testUnreadableOrCorruptBacklogIsNeverReportedEmpty() async throws {
        let reference = TransferTaskReference(itemID: itemID("a"), generation: 3, taskIdentifier: 5)
        let kept = StoredEvent(sequence: 7, receipt: nil, event: StoredTransferEvent(.failed(reference, .cancelled))!)
        let faults: [(String, (TransferInbox) throws -> Void, (TransferInbox) throws -> Void)] = [
            ("corrupt event", { inbox in
                try Data("{not json".utf8).write(to: inbox.events.appendingPathComponent("00000000000000000009.json"))
            }, { inbox in
                try FileManager.default.removeItem(at: inbox.events.appendingPathComponent("00000000000000000009.json"))
            }),
            ("unreadable event", { inbox in
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inbox.events.appendingPathComponent("00000000000000000007.json").path)
            }, { inbox in
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: inbox.events.appendingPathComponent("00000000000000000007.json").path)
            }),
            ("unreadable directory", { inbox in
                try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: inbox.events.path)
            }, { inbox in
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.events.path)
            }),
            ("corrupt reservation", { inbox in
                try Data("garbage".utf8).write(to: inbox.stateFile)
            }, { inbox in
                try inbox.write(TransferInbox.State(reservedSequence: 20))
            }),
            ("corrupt receipt", { inbox in
                try Data("{}".utf8).write(to: inbox.receipts.appendingPathComponent("broken.json"))
            }, { inbox in
                try FileManager.default.removeItem(at: inbox.receipts.appendingPathComponent("broken.json"))
            }),
        ]
        for (name, breakIt, repair) in faults {
            let identifier = Harness.uniqueName("session")
            let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
            try inbox.prepare()
            try inbox.write(kept)
            try inbox.write(TransferInbox.State(reservedSequence: 20))
            try breakIt(inbox)

            let transport = makeTransport()
            let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
            let recorder = EventRecorder.record(session)
            let told = await recorder.wait { $0.contains { $0.payload == .backlogUnavailable } }
            XCTAssertTrue(told, name)
            let host = try await XCTUnwrapAsync(await transport.host(for: identifier))
            let loaded = await host.isInboxLoaded
            XCTAssertFalse(loaded, name)
            let early = await recorder.events
            XCTAssertFalse(early.hasBacklogMarker, "\(name): never an empty backlog")
            XCTAssertEqual(early.terminalCount, 0, name)
            XCTAssertEqual(early.first?.sequence, 0, "\(name): the notice is not a position in the stream")

            // Acknowledging what was delivered releases nothing that was never loaded.
            await session.acknowledge(through: 100)
            try repair(inbox)
            await host.retryStorage()
            let recovered = await recorder.wait { $0.hasBacklogMarker }
            XCTAssertTrue(recovered, name)
            let events = await recorder.events.filter { !isUnavailable($0) }
            XCTAssertEqual(events.first, TransferSessionEvent(sequence: 7, payload: .transfer(.failed(reference, .cancelled))), "\(name): the stored event is replayed with its number")
            XCTAssertGreaterThan(events.last?.sequence ?? 0, 20, "\(name): reserved numbers are not reused")
            await transport.invalidate(cancellingTasks: true)
        }
    }

    // MARK: Barrier

    func testBacklogMarkerWaitsForAnOlderOperationThatIsNotReadyYet() async throws {
        let identifier = Harness.uniqueName("session")
        let transport = makeTransport()
        _ = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))
        let queue = host.callbackQueue
        let channel = host.callbackChannel

        // An older delegate operation that is not ready (its dependency has not run) and that
        // carries a terminal callback.
        let gate = BlockOperation {}
        let description = TransferTaskReference.taskDescription(itemID: itemID("late"), generation: 3)
        let older = BlockOperation {
            channel.yield(.completed(taskIdentifier: 4_242, description: description, failure: .network(code: URLError.networkConnectionLost.rawValue)))
        }
        older.addDependency(gate)
        queue.addOperation(older)

        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        let overtaken = await recorder.wait(timeout: 0.5) { $0.hasBacklogMarker }
        XCTAssertFalse(overtaken, "the marker never overtakes an operation queued before it")

        OperationQueue().addOperation(gate)
        let arrived = await recorder.wait { $0.hasBacklogMarker }
        XCTAssertTrue(arrived)
        let events = await recorder.events
        let terminal = try XCTUnwrap(events.firstIndex { if case .transfer(.failed(let reference, _)) = $0.payload { return reference.itemID == itemID("late") } else { return false } })
        let marker = try XCTUnwrap(events.firstIndex { $0.payload == .backlogDelivered })
        XCTAssertLessThan(terminal, marker)
    }

    // MARK: Symbolic links

    func testTransferDirectoryThroughASymbolicLinkIsRefused() async throws {
        let outside = try TemporaryDirectory("transfer-outside")
        defer { outside.remove() }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("transfer"), withDestinationURL: outside.url)

        do {
            _ = try await makeTransport().makeSession(identifier: Harness.uniqueName("session"), storageRoot: root)
            XCTFail("an inbox behind a symbolic link was used")
        } catch {
            XCTAssertNotNil(error as? TransferFailure)
        }
        XCTAssertEqual(entries(outside.url), [], "nothing was created outside the root")
    }

    func testCaptureAndResumeDataThroughSymbolicLinksAreRefused() async throws {
        let outside = try TemporaryDirectory("transfer-outside")
        defer { outside.remove() }
        let identifier = Harness.uniqueName("session")
        let transport = makeTransport()
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)

        // Resume data named by the index is a link to a file outside the root: never read, never
        // deleted through the link.
        let secret = outside.appending("secret")
        try mediaBytes(64).write(to: secret)
        let link = root.appendingPathComponent("staging/resume-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        _ = try await session.submit(submission("/ok", size: 1_000, item: "resumed", resume: path("staging/resume-link")))
        _ = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "the link is left alone")

        // `staging` itself replaced by a link: the capture is refused, nothing lands outside.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: root.appendingPathComponent("staging"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("staging"), withDestinationURL: outside.url)
        _ = try await session.submit(submission("/ok", size: 1_000, item: "linked"))
        _ = await recorder.wait { $0.terminalCount >= 2 }
        let terminal = await recorder.terminalEvents
        let linked = terminal.first { if case .failed(let reference, _) = $0 { return reference.itemID == itemID("linked") } else { return false } }
        guard case .failed(_, .storage(_))? = linked else { return XCTFail("\(terminal)") }
        XCTAssertEqual(entries(outside.url), ["secret"], "no capture outside the root")
    }
}

extension TransferInbox {
    /// Stored events that decode, for assertions.
    func storedEvents() -> [StoredEvent] {
        (try? load().events) ?? []
    }

    /// Receipts that decode, for assertions.
    func pendingReceipts() -> [CaptureReceipt] {
        (try? load().receipts) ?? []
    }
}
