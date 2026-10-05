//
//  BackgroundSessionTests.swift
//  DownloadKitTests
//
//  The background mode of the URLSession adapter, as far as macOS tests can reach it: the
//  configuration each mode builds, task descriptions carrying the session's identity, the
//  wake-drained marker's place in the ordered stream, and restart intents read back after a
//  relaunch.
//
//  A background session's transfers run in a system process that URLProtocol stubs do not
//  reach, so no test here runs a background transfer end to end. The wake marker and the
//  restart are driven through the same host code the background delegate feeds, on a stubbed
//  foreground session.
//

import Foundation
import XCTest
@testable import DownloadKit

final class BackgroundSessionTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var transports: [URLSessionTransport] = []

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("background")
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

    private static let stubOptions = URLSessionTransport.Options(now: { referenceDate }, configure: { configuration in
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
    })

    // MARK: Configuration

    func testBackgroundConfigurationMapsTheStableIdentifierLaunchEventsAndPolicy() {
        let options = URLSessionTransport.Options(mode: .background, resourceTimeout: 3_600)
        let configuration = options.makeConfiguration(identifier: "com.example.downloads")
        XCTAssertEqual(configuration.identifier, "com.example.downloads")
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertFalse(configuration.isDiscretionary, "a download a person asked for is not discretionary")
        XCTAssertFalse(configuration.allowsCellularAccess)
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 3_600)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)

        let deferred = NetworkPolicy(allowsCellular: true, allowsExpensive: true, allowsConstrained: true, scheduling: .deferred)
        let opportunistic = URLSessionTransport.Options(mode: .background, sessionNetworkAccess: deferred).makeConfiguration(identifier: "com.example.later")
        XCTAssertTrue(opportunistic.isDiscretionary, "deferred scheduling lets the system postpone the session's tasks")
        XCTAssertTrue(opportunistic.allowsCellularAccess)
        XCTAssertTrue(opportunistic.allowsExpensiveNetworkAccess)
        XCTAssertTrue(opportunistic.allowsConstrainedNetworkAccess)
        XCTAssertEqual(opportunistic.timeoutIntervalForResource, 7 * 24 * 60 * 60, "the system's own default")
    }

    func testForegroundConfigurationIsEphemeralWithTheSameNetworkMapping() {
        let configuration = URLSessionTransport.Options(sessionNetworkAccess: .anyNetwork, resourceTimeout: 600).makeConfiguration(identifier: "ignored")
        XCTAssertNil(configuration.identifier, "an ephemeral session has no background identifier")
        XCTAssertFalse(configuration.sessionSendsLaunchEvents)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertTrue(configuration.allowsCellularAccess)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 600)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    func testBackgroundTransportsShareOneProcessWideRegistry() {
        let first = URLSessionTransport(options: .init(mode: .background))
        let second = URLSessionTransport(options: .init(mode: .background))
        let foreground = URLSessionTransport()
        XCTAssertTrue(first.usesProcessWideSessions)
        XCTAssertTrue(second.usesProcessWideSessions, "one session object per background identifier in a process")
        XCTAssertFalse(foreground.usesProcessWideSessions)
    }

    // MARK: Task descriptions

    func testTaskDescriptionsCarryTheSessionIdentity() {
        let submission = TransferSubmission(itemID: itemID("series/episode 7"), generation: 42, url: URL(string: "https://media.example.com/a")!, policy: .default, resumeDataPath: nil, expectedLength: nil)
        let description = submission.taskDescription(sessionIdentifier: "com.example.downloads")
        XCTAssertTrue(description.hasPrefix("downloadkit/2/"))
        XCTAssertFalse(description.contains("com.example"), "the identifier is hashed, not spelled out")

        let mine = TransferTaskReference(taskDescription: description, taskIdentifier: 9, sessionIdentifier: "com.example.downloads")
        XCTAssertEqual(mine, TransferTaskReference(itemID: itemID("series/episode 7"), generation: 42, taskIdentifier: 9))
        XCTAssertNil(TransferTaskReference(taskDescription: description, taskIdentifier: 9, sessionIdentifier: "com.example.other"))
        XCTAssertEqual(TransferTaskReference(taskDescription: description, taskIdentifier: 9)?.generation, 42, "the session-blind parse reads both formats")

        // Format 1 (no session) is still accepted for any session.
        XCTAssertNotNil(TransferTaskReference(taskDescription: submission.taskDescription, taskIdentifier: 9, sessionIdentifier: "com.example.other"))
        // A malformed tag is not a package description.
        XCTAssertNil(TransferTaskReference(taskDescription: "downloadkit/2/XYZ/42/a", taskIdentifier: 1, sessionIdentifier: "s"))
        XCTAssertNil(TransferTaskReference(taskDescription: "downloadkit/2/0123456789ABCDEF/42/a", taskIdentifier: 1))
        XCTAssertEqual(TransferTaskReference.sessionTag("a").count, 16)
        XCTAssertEqual(TransferTaskReference.sessionTag("a"), TransferTaskReference.sessionTag("a"))
        XCTAssertNotEqual(TransferTaskReference.sessionTag("a"), TransferTaskReference.sessionTag("b"))
    }

    func testSubmittedTasksCarryTheirSessionsDescription() async throws {
        let transport = makeTransport()
        let identifier = Harness.uniqueName("session")
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let submission = TransferSubmission(itemID: itemID("a"), generation: 3, url: StubRoute.url("/slow", size: 1_000), policy: .default, resumeDataPath: nil, expectedLength: nil)
        let taskIdentifier = try await session.submit(submission)
        await realTimeEventually("the request arrived") { slowRequestHasArrived() }
        let tasks = await session.systemTasks()
        let listed = try XCTUnwrap(tasks.first { $0.taskIdentifier == taskIdentifier })
        XCTAssertEqual(listed.taskDescription, submission.taskDescription(sessionIdentifier: identifier))
        XCTAssertNotNil(listed.reference(inSession: identifier))
        XCTAssertNil(listed.reference(inSession: "another.session"))
        slowFirstByteGate.signal()
    }

    // MARK: Wake marker

    func testWakeMarkerFollowsTheEventsBeforeIt() async throws {
        let transport = makeTransport()
        let identifier = Harness.uniqueName("session")
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = await recorder.wait { $0.hasBacklogMarker }
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))

        let reference = TransferTaskReference(itemID: itemID("a"), generation: 2, taskIdentifier: 5)
        await host.inject(.completed(taskIdentifier: 5, description: TransferTaskReference.taskDescription(itemID: itemID("a"), generation: 2, sessionIdentifier: identifier), failure: .network(code: -1005)))
        await host.inject(.eventsFinished(order: WakeOrder.next()))
        let woke = await recorder.wait { $0.contains { $0.payload == .backgroundEventsFinished } }
        XCTAssertTrue(woke)
        let events = await recorder.events
        let failed = try XCTUnwrap(events.first { $0.payload == .transfer(.failed(reference, .network(code: -1005))) })
        let marker = try XCTUnwrap(events.first { $0.payload == .backgroundEventsFinished })
        XCTAssertLessThan(failed.sequence, marker.sequence)
    }

    func testWakeMarkerWaitsBehindAnEventThatCannotBeStoredYet() async throws {
        let transport = makeTransport()
        let identifier = Harness.uniqueName("session")
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = await recorder.wait { $0.hasBacklogMarker }
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inbox.events.path)
        await host.inject(.completed(taskIdentifier: 5, description: TransferTaskReference.taskDescription(itemID: itemID("a"), generation: 2, sessionIdentifier: identifier), failure: .network(code: nil)))
        // The marker's place among the wake handlers is taken in the callback, before the
        // storage delay; a handler accepted meanwhile is after it.
        let order = WakeOrder.next()
        await host.inject(.eventsFinished(order: order))
        await realTimeEventually("event and marker pending") { await host.pendingCount == 2 }
        let acceptedMeanwhile = WakeOrder.next()
        let early = await recorder.events
        XCTAssertFalse(early.contains { $0.payload == .backgroundEventsFinished }, "the marker never overtakes an unstored event")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.events.path)
        await host.retryStorage()
        let woke = await recorder.wait { $0.contains { $0.payload == .backgroundEventsFinished } }
        XCTAssertTrue(woke)
        let events = await recorder.events
        let failedIndex = try XCTUnwrap(events.firstIndex { if case .transfer(.failed) = $0.payload { return true } else { return false } })
        let markerIndex = try XCTUnwrap(events.firstIndex { $0.payload == .backgroundEventsFinished })
        XCTAssertLessThan(failedIndex, markerIndex)
        XCTAssertLessThan(events[failedIndex].sequence, events[markerIndex].sequence)
        XCTAssertEqual(events[markerIndex].wakeOrder, order, "the order taken in the callback survives the delay")
        XCTAssertLessThan(events[markerIndex].wakeOrder, acceptedMeanwhile)
    }

    func testWakeMarkerArrivingWhileNoManagerReadsIsDeliveredToTheNextOne() async throws {
        let transport = makeTransport()
        let identifier = Harness.uniqueName("session")
        let first = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))
        // The first manager reads, then detaches.
        let reader = Task { for await _ in first.events {} }
        reader.cancel()
        await reader.value

        let order = WakeOrder.next()
        await host.inject(.eventsFinished(order: order))
        let next = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(next)
        let woke = await recorder.wait { $0.contains { $0.payload == .backgroundEventsFinished } }
        XCTAssertTrue(woke, "the wake marker is owed to the next manager")
        let markers = await recorder.events.filter { $0.payload == .backgroundEventsFinished }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.wakeOrder, order, "an owed marker keeps its place among the wake handlers")
    }

    // MARK: Restarts across a relaunch

    func testRestartOfATaskFromAnEarlierLaunchUsesTheSystemsRequestAndNeverFails() async throws {
        let transport = makeTransport()
        let identifier = Harness.uniqueName("session")
        let session = try await transport.makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = await recorder.wait { $0.hasBacklogMarker }
        let host = try await XCTUnwrapAsync(await transport.host(for: identifier))

        // A continuation submitted by an earlier process was refused: this process never saw
        // its submission, only the system's copy of the request.
        var refused = URLRequest(url: StubRoute.url("/ok", size: 2_000))
        refused.setValue("bytes=1000-", forHTTPHeaderField: "Range")
        refused.setValue("\"v1\"", forHTTPHeaderField: "If-Range")
        let description = TransferTaskReference.taskDescription(itemID: itemID("r"), generation: 5, sessionIdentifier: identifier)
        await host.inject(.restart(taskIdentifier: 4_242, description: description, request: refused))

        let finished = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(finished)
        let terminal = await recorder.terminalEvents
        XCTAssertEqual(terminal.count, 1)
        guard case .finished(let reference, _, let bytes, _) = terminal.first else { return XCTFail("restart became \(terminal)") }
        XCTAssertEqual(reference.itemID, itemID("r"))
        XCTAssertEqual(reference.generation, 5, "the same attempt, started from zero")
        XCTAssertEqual(bytes, 2_000, "the whole body, not a continuation")
        let replacement = await host.replacement(for: 4_242)
        XCTAssertEqual(replacement, reference.taskIdentifier)
        await realTimeEventually("the finished restart is forgotten") { await host.restartIntents.isEmpty }

        let plain = TransferSessionHost.restartRequest(from: refused)
        XCTAssertNil(plain.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(plain.value(forHTTPHeaderField: "If-Range"))
    }

    func testRestartIntentSurvivesARelaunch() async throws {
        let identifier = Harness.uniqueName("session")
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
        try inbox.prepare()
        // Written inside the earlier launch's callback, then completed with the replacement.
        try inbox.write(RestartIntent(taskIdentifier: 4_242, itemID: "r", generation: 5, replacement: 77))
        let description = TransferTaskReference.taskDescription(itemID: itemID("r"), generation: 5, sessionIdentifier: identifier)

        let host = try TransferSessionHost(identifier: identifier, storageRoot: root, options: Self.stubOptions, tasksOutliveProcess: true)
        await host.start()
        let stream = await host.subscribe()
        let recorder = EventRecorder()
        Task { for await event in stream { await recorder.append(event) } }
        _ = await recorder.wait { $0.hasBacklogMarker }
        let intents = await host.restartIntents
        let replacement = await host.replacement(for: 4_242)
        XCTAssertEqual(intents.map(\.taskIdentifier), [4_242])
        XCTAssertEqual(replacement, 77, "a cancel of the refused task reaches its replacement")

        // The refused task's own completion arrives after the relaunch: it is not a failure.
        await host.inject(.completed(taskIdentifier: 4_242, description: description, failure: nil))
        // The replacement then fails for real; that is reported, and the restart is finished.
        await host.inject(.completed(taskIdentifier: 77, description: description, failure: .network(code: -1009)))
        let reported = await recorder.wait { $0.terminalCount >= 1 }
        XCTAssertTrue(reported)
        let terminal = await recorder.terminalEvents
        XCTAssertEqual(terminal, [.failed(TransferTaskReference(itemID: itemID("r"), generation: 5, taskIdentifier: 77), .network(code: -1009))])
        await realTimeEventually("restart finished") { await host.restartIntents.isEmpty }
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: inbox.restarts.path)) ?? ["x"]).isEmpty)
        await host.invalidate(cancellingTasks: true)
    }

    func testForegroundRelaunchDropsRestartIntentsOfTasksThatCannotSurvive() async throws {
        let identifier = Harness.uniqueName("session")
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
        try inbox.prepare()
        try inbox.write(RestartIntent(taskIdentifier: 3, itemID: "r", generation: 5, replacement: 4))
        let session = try await makeTransport().makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        _ = await recorder.wait { $0.hasBacklogMarker }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.restarts.path), [])
    }

    func testUnreadableRestartIntentWithholdsTheBacklog() async throws {
        let identifier = Harness.uniqueName("session")
        let inbox = TransferInbox(storageRoot: root, sessionIdentifier: identifier)
        try inbox.prepare()
        try Data("{".utf8).write(to: inbox.restarts.appendingPathComponent("task-1.json"))
        let session = try await makeTransport().makeSession(identifier: identifier, storageRoot: root)
        let recorder = EventRecorder.record(session)
        let told = await recorder.wait { $0.contains { $0.payload == .backlogUnavailable } }
        XCTAssertTrue(told, "an unreadable restart is never read as no restart")
        let events = await recorder.events
        XCTAssertFalse(events.hasBacklogMarker)
    }
}
