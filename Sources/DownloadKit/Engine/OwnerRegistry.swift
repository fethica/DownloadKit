//
//  OwnerRegistry.swift
//  DownloadKit
//
//  Process-wide record of which manager owns which storage root and session identifier.
//  This is a registry of claims, not a manager singleton.
//

import Foundation

actor OwnerRegistry {
    static let shared = OwnerRegistry()

    private struct Claim {
        let token: UUID
        weak var owner: DownloadEngine?
    }

    private var roots: [String: Claim] = [:]
    private var sessions: [String: Claim] = [:]

    /// Claims `root` and `session` for `owner`. A claim whose owner was released is reused.
    func claim(root: String, session: String, owner: DownloadEngine) throws -> UUID {
        if roots[root]?.owner != nil || sessions[session]?.owner != nil {
            throw DownloadError.ownerAlreadyActive
        }
        let token = UUID()
        roots[root] = Claim(token: token, owner: owner)
        sessions[session] = Claim(token: token, owner: owner)
        return token
    }

    func release(_ token: UUID) {
        roots = roots.filter { $0.value.token != token }
        sessions = sessions.filter { $0.value.token != token }
    }
}
