//
//  NetworkPolicy.swift
//  DownloadKit
//

import Foundation

/// Which networks a download may use. Persisted; there is no ambiguous Wi-Fi flag.
///
/// The default, ``unmeteredOnly``, refuses cellular and expensive networks and defers
/// transfers while the network is constrained (Low Data Mode). A disallowed network makes an
/// item wait with ``WaitReason/networkPolicy``; it never fails and never spends a retry.
///
/// Non-expensive does not prove Wi-Fi (a Wi-Fi hotspot can be expensive, and an Ethernet
/// link is not Wi-Fi). Strict Wi-Fi is not offered because it cannot be enforced for
/// background transfers.
public struct NetworkPolicy: Hashable, Sendable, Codable {
    /// How eagerly the system should schedule transfers.
    public enum Scheduling: String, Hashable, Sendable, Codable {
        /// The user asked for this download now.
        case userInitiated
        /// Opportunistic work the system may postpone (for example until charging).
        case deferred
    }

    /// Allow cellular interfaces.
    public var allowsCellular: Bool
    /// Allow networks the system marks as expensive. Cellular is normally expensive too, so
    /// cellular use needs both flags.
    public var allowsExpensive: Bool
    /// Allow networks in Low Data Mode. When false, transfers wait while constrained.
    public var allowsConstrained: Bool
    public var scheduling: Scheduling

    public init(allowsCellular: Bool, allowsExpensive: Bool, allowsConstrained: Bool, scheduling: Scheduling = .userInitiated) {
        self.allowsCellular = allowsCellular
        self.allowsExpensive = allowsExpensive
        self.allowsConstrained = allowsConstrained
        self.scheduling = scheduling
    }

    /// Non-expensive, no cellular, deferred while constrained. The default.
    public static let unmeteredOnly = NetworkPolicy(allowsCellular: false, allowsExpensive: false, allowsConstrained: false)
    /// Any available network.
    public static let anyNetwork = NetworkPolicy(allowsCellular: true, allowsExpensive: true, allowsConstrained: true)
    /// The policy used when the host sets none.
    public static let `default` = unmeteredOnly

    /// Explains whether a transfer may use `path`. Used for honest wait reasons; it does not
    /// prove a request will succeed.
    public func evaluate(_ path: NetworkPathStatus) -> NetworkPolicyDecision {
        guard path.isSatisfied else { return .waiting(.connectivity) }
        if path.usesCellular && !allowsCellular { return .waiting(.networkPolicy) }
        if path.isExpensive && !allowsExpensive { return .waiting(.networkPolicy) }
        if path.isConstrained && !allowsConstrained { return .waiting(.networkPolicy) }
        return .allowed
    }
}

/// The result of ``NetworkPolicy/evaluate(_:)``.
public enum NetworkPolicyDecision: Hashable, Sendable {
    case allowed
    case waiting(WaitReason)
}

/// A snapshot of the current network path, as reported by a ``NetworkPathSource``.
public struct NetworkPathStatus: Hashable, Sendable {
    public var isSatisfied: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var usesCellular: Bool

    public init(isSatisfied: Bool, isExpensive: Bool = false, isConstrained: Bool = false, usesCellular: Bool = false) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.usesCellular = usesCellular
    }
}
