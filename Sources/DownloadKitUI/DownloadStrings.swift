//
//  DownloadStrings.swift
//  DownloadKitUI
//
//  Every user-visible string of the product, looked up by key. English ships in the package;
//  a host overrides any key with a `DownloadKitUI.strings` table in its main bundle, or with a
//  lookup closure in the environment.
//

import SwiftUI
import DownloadKit

/// The keys of every string DownloadKitUI shows. The English values are in the package's
/// `Localizable.strings`; keys ending in `.format` take `%@` arguments.
public enum DownloadStringKey: String, Sendable, CaseIterable {
    case indicatorLabel = "indicator.label"
    case statusNotDownloaded = "status.notDownloaded"
    case statusQueued = "status.queued"
    case statusActive = "status.active"
    case statusActiveFormat = "status.active.format"
    case statusWaitingPolicy = "status.waiting.networkPolicy"
    case statusWaitingConnectivity = "status.waiting.connectivity"
    case statusWaitingRetryFormat = "status.waiting.retry.format"
    case statusWaitingSystem = "status.waiting.system"
    case statusWaitingUnknown = "status.waiting.unknown"
    case statusPaused = "status.paused"
    case statusPausedFromStart = "status.paused.fromStart"
    case statusPausedFormat = "status.paused.format"
    case statusFailedFormat = "status.failed.format"
    case statusCompleted = "status.completed"
    case statusRemoving = "status.removing"
    case statusMissing = "status.missing"
    case bytesFormat = "bytes.format"
    case failureUnknown = "failure.unknown"
    case failureNetwork = "failure.network"
    case failureHTTPFormat = "failure.http.format"
    case failureStorageFull = "failure.storageFull"
    case failureStorage = "failure.storage"
    case failureFileProtection = "failure.fileProtection"
    case failureIntegrity = "failure.integrity"
    case failureUnauthorized = "failure.unauthorized"
    case failureInvalidResponse = "failure.invalidResponse"
    case failureCancelled = "failure.cancelled"
    case actionDownload = "action.download"
    case actionPause = "action.pause"
    case actionResume = "action.resume"
    case actionCancel = "action.cancel"
    case actionRetry = "action.retry"
    case actionRemove = "action.remove"
    case actionDownloadFormat = "action.download.format"
    case actionPauseFormat = "action.pause.format"
    case actionResumeFormat = "action.resume.format"
    case actionCancelFormat = "action.cancel.format"
    case actionRetryFormat = "action.retry.format"
    case actionRemoveFormat = "action.remove.format"
    case hintDownload = "hint.download"
    case hintPause = "hint.pause"
    case hintResume = "hint.resume"
    case hintCancel = "hint.cancel"
    case hintRetry = "hint.retry"
    case hintRemove = "hint.remove"
    case removeTitleFormat = "remove.title.format"
    case removeTitleGeneric = "remove.title.generic"
    case removeMessage = "remove.message"
    case removeConfirm = "remove.confirm"
    case removeKeep = "remove.keep"
    case removeGroup = "remove.group"
    case removeGroupFormat = "remove.group.format"
    case listEmpty = "list.empty"
    case listUngrouped = "list.ungrouped"
    case policyTitle = "policy.title"
    case policyUnmeteredOnly = "policy.unmeteredOnly"
    case policyUnmeteredIncludingLowData = "policy.unmeteredIncludingLowData"
    case policyAnyNetwork = "policy.anyNetwork"
    case policyCustom = "policy.custom"
    case policyFooter = "policy.footer"
    case bannerRestoringTitle = "banner.restoring.title"
    case bannerRestoringDetail = "banner.restoring.detail"
    case bannerUnresolvedTitle = "banner.unresolved.title"
    case bannerUnresolvedFormat = "banner.unresolved.format"
    case bannerStorageTitle = "banner.storage.title"
    case bannerStorageFormat = "banner.storage.format"
    case bannerStartTitle = "banner.start.title"
    case errorTitle = "error.title"
    case errorDismiss = "error.dismiss"
    case errorNotStarted = "error.notStarted"
    case errorItemBeingRemoved = "error.itemBeingRemoved"
    case errorUnknownItem = "error.unknownItem"
    case errorConflictingRequest = "error.conflictingRequest"
    case errorPersistenceFailed = "error.persistenceFailed"
    case errorReconciliationUnresolved = "error.reconciliationUnresolved"
    case errorStorageUnavailable = "error.storageUnavailable"
    case errorUnsupportedIndex = "error.unsupportedIndex"
    case errorFileAccessFailed = "error.fileAccessFailed"
    case errorAnotherOwner = "error.anotherOwner"
    case errorOther = "error.other"
}

/// Looks up and formats DownloadKitUI's strings.
///
/// Order of lookup for each key: the `lookup` closure, if it returns a value; then the host's
/// `DownloadKitUI.strings` table in the main bundle (``hostTableName``); then the package's
/// English `Localizable.strings`. Set a custom value with
/// `.environment(\.downloadStrings, DownloadStrings { key in ... })`.
@available(iOS 15, macOS 12, *)
public struct DownloadStrings: Sendable {
    /// The table name a host adds to its main bundle to override keys.
    public static let hostTableName = "DownloadKitUI"
    /// The package lookup without a custom closure.
    public static let standard = DownloadStrings()

    private let lookup: (@Sendable (_ key: String) -> String?)?

    public init(lookup: (@Sendable (_ key: String) -> String?)? = nil) {
        self.lookup = lookup
    }

    /// The string for `key`.
    public func text(_ key: DownloadStringKey) -> String {
        if let custom = lookup?(key.rawValue) { return custom }
        let missing = "\u{1}missing\u{1}"
        let host = Bundle.main.localizedString(forKey: key.rawValue, value: missing, table: Self.hostTableName)
        if host != missing { return host }
        return Bundle.module.localizedString(forKey: key.rawValue, value: nil, table: nil)
    }

    /// The format string for `key` with `arguments` substituted (`%@` placeholders).
    public func text(_ key: DownloadStringKey, _ arguments: String...) -> String {
        String(format: text(key), arguments: arguments.map { $0 as CVarArg })
    }

    // MARK: Composed strings

    /// A short, complete description of `indicator`, used as the status line and as the
    /// accessibility value.
    public func status(_ indicator: DownloadIndicator) -> String {
        switch indicator {
        case .notDownloaded: return text(.statusNotDownloaded)
        case .queued: return text(.statusQueued)
        case .active(let progress):
            guard let progress else { return text(.statusActive) }
            return text(.statusActiveFormat, percent(progress))
        case .waiting(let reason, _):
            switch reason {
            case .networkPolicy: return text(.statusWaitingPolicy)
            case .connectivity: return text(.statusWaitingConnectivity)
            case .retryScheduled(let date): return text(.statusWaitingRetryFormat, date.formatted(date: .omitted, time: .shortened))
            case .system: return text(.statusWaitingSystem)
            case .unknown: return text(.statusWaitingUnknown)
            }
        case .paused(let resumable, let progress):
            let base = resumable ? text(.statusPaused) : text(.statusPausedFromStart)
            guard resumable, let progress else { return base }
            return text(.statusPausedFormat, percent(progress))
        case .failed(let failure): return text(.statusFailedFormat, self.failure(failure))
        case .completed: return text(.statusCompleted)
        case .removing: return text(.statusRemoving)
        case .missing: return text(.statusMissing)
        }
    }

    /// A short reason for `failure`.
    public func failure(_ failure: DownloadFailure) -> String {
        switch failure.kind {
        case .unknown: return text(.failureUnknown)
        case .network: return text(.failureNetwork)
        case .http: return failure.httpStatus.map { text(.failureHTTPFormat, String($0)) } ?? text(.failureUnknown)
        case .storageFull: return text(.failureStorageFull)
        case .storage: return text(.failureStorage)
        case .fileProtection: return text(.failureFileProtection)
        case .integrity: return text(.failureIntegrity)
        case .unauthorized: return text(.failureUnauthorized)
        case .invalidResponse: return text(.failureInvalidResponse)
        case .cancelled: return text(.failureCancelled)
        }
    }

    /// "12 MB of 40 MB", or the received size alone when the total is unknown.
    public func bytes(_ item: DownloadItem) -> String? {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        switch item.indicator {
        case .completed:
            return item.expectedBytes.map { formatter.string(fromByteCount: $0) }
        case .active, .paused, .waiting:
            let received = formatter.string(fromByteCount: item.receivedBytes)
            guard let expected = item.expectedBytes else { return item.receivedBytes > 0 ? received : nil }
            return text(.bytesFormat, received, formatter.string(fromByteCount: expected))
        default:
            return nil
        }
    }

    /// The short title of `action`.
    public func title(_ action: DownloadAction) -> String {
        switch action {
        case .pause: return text(.actionPause)
        case .resume: return text(.actionResume)
        case .cancel: return text(.actionCancel)
        case .retry: return text(.actionRetry)
        case .remove: return text(.actionRemove)
        }
    }

    /// The accessibility label of `action` applied to the item titled `itemTitle`.
    public func label(_ action: DownloadAction, itemTitle: String) -> String {
        switch action {
        case .pause: return text(.actionPauseFormat, itemTitle)
        case .resume: return text(.actionResumeFormat, itemTitle)
        case .cancel: return text(.actionCancelFormat, itemTitle)
        case .retry: return text(.actionRetryFormat, itemTitle)
        case .remove: return text(.actionRemoveFormat, itemTitle)
        }
    }

    /// The accessibility hint of `action`.
    public func hint(_ action: DownloadAction) -> String {
        switch action {
        case .pause: return text(.hintPause)
        case .resume: return text(.hintResume)
        case .cancel: return text(.hintCancel)
        case .retry: return text(.hintRetry)
        case .remove: return text(.hintRemove)
        }
    }

    public func title(_ choice: NetworkPolicyChoice) -> String {
        switch choice {
        case .unmeteredOnly: return text(.policyUnmeteredOnly)
        case .unmeteredIncludingLowData: return text(.policyUnmeteredIncludingLowData)
        case .anyNetwork: return text(.policyAnyNetwork)
        }
    }

    /// The message for a command that did not go through.
    public func message(_ reason: DownloadCommandFailure.Reason) -> String {
        switch reason {
        case .notStarted: return text(.errorNotStarted)
        case .itemBeingRemoved: return text(.errorItemBeingRemoved)
        case .unknownItem: return text(.errorUnknownItem)
        case .conflictingRequest: return text(.errorConflictingRequest)
        case .persistenceFailed: return text(.errorPersistenceFailed)
        case .reconciliationUnresolved: return text(.errorReconciliationUnresolved)
        case .storageUnavailable: return text(.errorStorageUnavailable)
        case .unsupportedIndex: return text(.errorUnsupportedIndex)
        case .fileAccessFailed: return text(.errorFileAccessFailed)
        case .anotherOwner: return text(.errorAnotherOwner)
        case .other: return text(.errorOther)
        }
    }

    /// The banner's title and detail.
    public func banner(_ banner: DownloadBanner) -> (title: String, detail: String) {
        switch banner {
        case .restoring: return (text(.bannerRestoringTitle), text(.bannerRestoringDetail))
        case .unresolved(let count): return (text(.bannerUnresolvedTitle), text(.bannerUnresolvedFormat, count.formatted()))
        case .storageFailed(let count): return (text(.bannerStorageTitle), text(.bannerStorageFormat, count.formatted()))
        case .startFailed(let reason): return (text(.bannerStartTitle), message(reason))
        }
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

@available(iOS 15, macOS 12, *)
private struct DownloadStringsKey: EnvironmentKey {
    static let defaultValue = DownloadStrings.standard
}

@available(iOS 15, macOS 12, *)
extension EnvironmentValues {
    /// The strings DownloadKitUI views use. Defaults to ``DownloadStrings/standard``.
    public var downloadStrings: DownloadStrings {
        get { self[DownloadStringsKey.self] }
        set { self[DownloadStringsKey.self] = newValue }
    }
}
