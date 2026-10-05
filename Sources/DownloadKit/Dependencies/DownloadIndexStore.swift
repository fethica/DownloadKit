//
//  DownloadIndexStore.swift
//  DownloadKit
//

import Foundation

/// The durable index of records.
///
/// Contract:
/// - ``load()`` returns `nil` for a store that was never written, the contents otherwise.
/// - A stored schema newer than ``IndexSchema/currentVersion`` throws
///   ``DownloadError/unsupportedSchema(found:supported:)``; an unreadable store throws
///   ``DownloadError/corruptIndex``. Neither case may modify, reset or recreate the store.
/// - ``apply(_:)`` is atomic: all of the change set or none of it.
/// - Paths are stored exactly as the relative paths given.
///
/// The production store is ``SQLiteIndexStore`` (system SQLite library, one connection
/// confined to one actor, schema version in its own table).
public protocol DownloadIndexStore: Sendable {
    func load() async throws -> IndexContents?
    func apply(_ changes: IndexChangeSet) async throws
}
