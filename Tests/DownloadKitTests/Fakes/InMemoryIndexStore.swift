import Foundation
@testable import DownloadKit

/// An index store that keeps the encoded index in memory.
///
/// Every write and read goes through JSON so the Codable record shape is exercised exactly as
/// a durable store would see it.
actor InMemoryIndexStore: DownloadIndexStore {
    private var data: Data?
    private(set) var applyCount = 0
    private var failWrites = false
    private var corrupt = false
    private let log: CallLog?

    init(contents: IndexContents? = nil, log: CallLog? = nil) {
        self.data = contents.map { try! Self.encoder.encode($0) }
        self.log = log
    }

    var contents: IndexContents? {
        data.flatMap { try? Self.decoder.decode(IndexContents.self, from: $0) }
    }

    var rawData: Data? { data }

    func setFailWrites(_ fail: Bool) { failWrites = fail }
    func setCorrupt() { corrupt = true }

    func load() throws -> IndexContents? {
        if corrupt { throw DownloadError.corruptIndex }
        guard let data else { return nil }
        let header = try Self.decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion <= IndexSchema.currentVersion else {
            throw DownloadError.unsupportedSchema(found: header.schemaVersion, supported: IndexSchema.currentVersion)
        }
        return try Self.decoder.decode(IndexContents.self, from: data)
    }

    func apply(_ changes: IndexChangeSet) async throws {
        let ids = (changes.upserts.map(\.id.rawValue) + changes.deletions.map { "-" + $0.rawValue }).joined(separator: ",")
        await log?.append("persist \(ids)")
        if failWrites { throw FakeError.injected }
        if let data, let header = try? Self.decoder.decode(SchemaHeader.self, from: data), header.schemaVersion > IndexSchema.currentVersion {
            throw DownloadError.unsupportedSchema(found: header.schemaVersion, supported: IndexSchema.currentVersion)
        }
        let next = changes.applied(to: try load())
        data = try Self.encoder.encode(next)
        applyCount += 1
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

enum FakeError: Error {
    case injected
}
