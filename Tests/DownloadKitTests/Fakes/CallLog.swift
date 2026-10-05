import Foundation

/// Records calls across fakes so tests can assert ordering.
actor CallLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}
