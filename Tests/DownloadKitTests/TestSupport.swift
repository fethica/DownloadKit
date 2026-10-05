//
//  TestSupport.swift
//  DownloadKitTests
//

import Foundation
@testable import DownloadKit

let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

func itemID(_ raw: String) -> DownloadID {
    // Test identifiers are literals that satisfy the rules.
    try! DownloadID(raw)
}

func path(_ raw: String) -> RelativePath {
    try! RelativePath(raw)
}

func makeRequest(
    _ raw: String,
    url: String = "https://media.example.com/files/one.m4a",
    revision: String = "r1",
    expectedLength: Int64? = nil,
    policy: NetworkPolicy? = nil,
    title: String? = nil
) -> DownloadRequest {
    DownloadRequest(
        id: itemID(raw),
        url: URL(string: url)!,
        revision: ContentRevision(revision),
        expectedLength: expectedLength,
        metadata: DownloadMetadata(title: title),
        policy: policy
    )
}

func reference(_ raw: String, generation: UInt64, task: Int = 7) -> TransferTaskReference {
    TransferTaskReference(itemID: itemID(raw), generation: generation, taskIdentifier: task)
}

extension DownloadStateMachine {
    static func fresh(policy: NetworkPolicy = .default, retry: RetryPolicy = .default, session: String = "session") -> DownloadStateMachine {
        DownloadStateMachine(contents: nil, sessionIdentifier: session, defaultPolicy: policy, retryPolicy: retry)
    }

    func record(_ raw: String) -> IndexRecord? {
        records[itemID(raw)]
    }

    func phase(_ raw: String) -> RecordPhase? {
        records[itemID(raw)]?.phase
    }

    func generation(_ raw: String) -> UInt64 {
        records[itemID(raw)]?.generation ?? 0
    }

    /// Enqueues and binds the task, returning the generation.
    @discardableResult
    mutating func enqueueAndBind(_ raw: String, task: Int = 7, now: Date = referenceDate, request: DownloadRequest? = nil) throws -> UInt64 {
        _ = try handle(.enqueue(request ?? makeRequest(raw)), now: now)
        let generation = self.generation(raw)
        _ = handle(.taskBound(itemID(raw), generation: generation, taskIdentifier: task), now: now, jitter: 0)
        return generation
    }

    mutating func send(_ event: TransferEvent, now: Date = referenceDate, jitter: Double = 0) -> Outcome {
        handle(.transfer(event), now: now, jitter: jitter)
    }
}

extension DownloadStateMachine.Outcome {
    var submissions: [TransferSubmission] {
        effects.compactMap { if case .submit(let submission) = $0 { return submission } else { return nil } }
    }

    var cancellations: [DownloadStateMachine.Effect] {
        effects.filter { if case .cancelTask = $0 { return true } else { return false } }
    }
}
