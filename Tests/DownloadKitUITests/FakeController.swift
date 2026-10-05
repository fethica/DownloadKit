//
//  FakeController.swift
//  DownloadKitUITests
//
//  A scripted DownloadControlling: every snapshot subscription is its own stream, commands are
//  recorded, and a command can be held until the test releases it.
//

import Foundation
import DownloadKit
import DownloadKitUI

actor FakeController: DownloadControlling {
    private(set) var calls: [String] = []
    private(set) var subscriptions = 0
    private(set) var terminations = 0
    private var continuations: [UUID: AsyncStream<[DownloadSnapshot]>.Continuation] = [:]

    var status: ReconciliationStatus = .resolved
    var policy: NetworkPolicy = .default
    var commandError: (any Error)?
    var localResult: LocalFileResult = .unavailable(.notDownloaded)
    var localError: (any Error)?
    private var holdCommands = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var liveSubscriptions: Int { continuations.count }

    func setStatus(_ status: ReconciliationStatus) { self.status = status }
    func setPolicy(_ policy: NetworkPolicy) { self.policy = policy }
    func setCommandError(_ error: (any Error)?) { commandError = error }
    func setLocal(_ result: LocalFileResult, error: (any Error)? = nil) { localResult = result; localError = error }
    func setHoldCommands(_ hold: Bool) { holdCommands = hold }

    func releaseHeld() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    var heldCount: Int { held.count }

    /// Sends `list` to every live subscription.
    func send(_ list: [DownloadSnapshot]) {
        for continuation in continuations.values { continuation.yield(list) }
    }

    /// Ends every live subscription from the source side.
    func finishAll() {
        for continuation in continuations.values { continuation.finish() }
    }

    private func terminated(_ id: UUID) {
        continuations[id] = nil
        terminations += 1
    }

    // MARK: DownloadControlling

    func snapshots() -> AsyncStream<[DownloadSnapshot]> {
        calls.append("snapshots")
        subscriptions += 1
        let id = UUID()
        let (stream, continuation) = AsyncStream<[DownloadSnapshot]>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.terminated(id) }
        }
        continuations[id] = continuation
        return stream
    }

    private func command(_ name: String) async throws {
        calls.append(name)
        if holdCommands {
            await withCheckedContinuation { held.append($0) }
        }
        if let commandError { throw commandError }
    }

    func pause(_ id: DownloadID) async throws { try await command("pause \(id)") }
    func resume(_ id: DownloadID) async throws { try await command("resume \(id)") }
    func cancel(_ id: DownloadID) async throws { try await command("cancel \(id)") }
    func retry(_ id: DownloadID) async throws { try await command("retry \(id)") }
    func remove(_ ids: [DownloadID]) async throws { try await command("remove \(ids.map(\.rawValue).joined(separator: ","))") }

    func defaultPolicy() -> NetworkPolicy {
        calls.append("defaultPolicy")
        return policy
    }

    func setDefaultPolicy(_ policy: NetworkPolicy) async throws {
        try await command("setDefaultPolicy")
        self.policy = policy
    }

    func reconciliationStatus() -> ReconciliationStatus {
        status
    }

    func localFile(for id: DownloadID) throws -> LocalFileResult {
        calls.append("localFile \(id)")
        if let localError { throw localError }
        return localResult
    }

    func endAccess(_ lease: LocalFileLease) {
        calls.append("endAccess \(lease.id)")
    }
}

func snapshot(
    _ id: String,
    _ state: DownloadState,
    bytes: Int64 = 0,
    expected: Int64? = nil,
    title: String? = nil,
    group: String? = nil
) -> DownloadSnapshot {
    DownloadSnapshot(
        id: try! DownloadID(id),
        revision: ContentRevision("r1"),
        metadata: DownloadMetadata(title: title, group: group),
        state: state,
        bytesWritten: bytes,
        expectedBytes: expected,
        automaticRetryCount: 0,
        retryAt: nil,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

func id(_ raw: String) -> DownloadID {
    try! DownloadID(raw)
}

/// Polls `condition` on the main actor, yielding between checks, for at most `seconds`.
@MainActor
func eventually(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}
