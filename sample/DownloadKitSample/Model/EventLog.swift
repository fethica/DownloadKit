//
//  EventLog.swift
//  DownloadKitSample
//
//  A bounded, redacted log of what the app saw: launches, wakes, handler calls, state
//  changes, commands. It is kept across launches, so what happened during a background
//  relaunch can be read when the app is opened again.
//

import Foundation
import os
import DownloadKitUI

@MainActor
final class EventLog: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: Int
        let text: String
    }

    @Published private(set) var entries: [Entry] = []

    private let limit = 300
    private let key = "eventLog"
    private var counter = 0
    private let logger = Logger(subsystem: "com.fethica.downloadkit.sample", category: "events")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        entries = stored.map { text in
            counter += 1
            return Entry(id: counter, text: text)
        }
    }

    /// Records `text` after removing any URL or absolute path from it.
    func record(_ text: String) {
        let line = formatter.string(from: Date()) + "  " + DiagnosticRedaction.redact(text)
        logger.log("\(line, privacy: .public)")
        counter += 1
        entries.append(Entry(id: counter, text: line))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        UserDefaults.standard.set(entries.map(\.text), forKey: key)
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
