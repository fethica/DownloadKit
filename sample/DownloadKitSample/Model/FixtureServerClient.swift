//
//  FixtureServerClient.swift
//  DownloadKitSample
//
//  The fixture server's address and its control endpoint. The server runs on a Mac, outside
//  the app: a server inside the app would stop when the app is suspended.
//

import Foundation

@MainActor
final class FixtureServerClient: ObservableObject {
    private static let key = "fixtureServerBaseURL"
    /// Loopback reaches the Mac from the simulator. On a device, use the Mac's LAN address
    /// printed by the server.
    static let defaultBaseURL = "http://127.0.0.1:8080"

    @Published var baseURLText: String {
        didSet { UserDefaults.standard.set(baseURLText, forKey: Self.key) }
    }

    private let session = URLSession(configuration: .ephemeral)

    init() {
        baseURLText = UserDefaults.standard.string(forKey: Self.key) ?? Self.defaultBaseURL
    }

    var baseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    func url(for path: String) -> URL? {
        baseURL?.appendingPathComponent(path)
    }

    /// Checks the server and returns a one-line result.
    func check() async -> String {
        guard let url = url(for: "manifest.json") else { return "Not a valid http address" }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = object["files"] as? [[String: Any]] else { return "Unexpected answer" }
            let mismatched = files.filter { file in
                guard let name = file["name"] as? String, let digest = file["sha256"] as? String else { return true }
                return FixtureFile.all.first { $0.name == name }?.sha256 != digest
            }
            return mismatched.isEmpty ? "Reachable, \(files.count) files, digests match" : "Reachable, but \(mismatched.count) digests differ from the catalog"
        } catch {
            return "Unreachable: \((error as? URLError)?.code.rawValue ?? -1)"
        }
    }

    /// Serves `file` with `scenario` for the next `times` requests (0: until cleared).
    func setScenario(_ scenario: FixtureScenario, for file: FixtureFile, times: Int) async -> String {
        var items = [URLQueryItem(name: "file", value: file.name), URLQueryItem(name: "scenario", value: scenario.rawValue)]
        if times > 0 { items.append(URLQueryItem(name: "times", value: String(times))) }
        return await control("set", items)
    }

    func clearScenarios() async -> String {
        await control("clear", [])
    }

    private func control(_ action: String, _ items: [URLQueryItem]) async -> String {
        guard let base = url(for: "control/\(action)"), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return "Not a valid http address"
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return "Not a valid http address" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? "Applied" : "Refused (\(status))"
        } catch {
            return "Unreachable: \((error as? URLError)?.code.rawValue ?? -1)"
        }
    }
}
