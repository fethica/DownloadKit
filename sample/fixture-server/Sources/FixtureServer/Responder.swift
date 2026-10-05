//
//  Responder.swift
//  FixtureServer
//
//  Turns a request into a response plan. Pure apart from the override store, so the routes
//  and scenarios are tested without sockets.
//

import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Lowercased names.
    var headers: [String: String]

    init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method.uppercased()
        let components = URLComponents(string: target)
        self.path = components?.percentEncodedPath ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        if !body.isEmpty, let form = String(data: body, encoding: .utf8), let parsed = URLComponents(string: "?" + form) {
            for item in parsed.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
    }
}

struct ResponsePlan: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    /// Bytes of `body` actually sent; `nil` sends all.
    var sendLimit: Int?
    /// Reset the connection (instead of a clean close) after sending.
    var resetAfterSend = false
    /// Seconds before the status line.
    var delay: TimeInterval = 0
    /// Body rate limit; `nil` is unlimited.
    var bytesPerSecond: Int?

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

struct Responder: Sendable {
    static let lastModified = "Mon, 05 Oct 2026 00:00:00 GMT"
    static let htmlPage = Data("<!DOCTYPE html><html><head><title>Sign in</title></head><body><form>Sign in to continue</form></body></html>".utf8)

    let fixtures: [String: Fixture]
    let order: [String]
    let store: OverrideStore
    /// The default body rate for files, `nil` for unlimited.
    let defaultRate: Int?

    init(fixtures: [Fixture], store: OverrideStore, defaultRate: Int?) {
        self.fixtures = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0) })
        self.order = fixtures.map(\.name)
        self.store = store
        self.defaultRate = defaultRate
    }

    func plan(for request: HTTPRequest) -> ResponsePlan {
        guard request.method == "GET" || request.method == "HEAD" || (request.method == "POST" && request.path.hasPrefix("/control/")) else {
            return text(405, "method not allowed")
        }
        let parts = request.path.split(separator: "/").map(String.init)
        switch parts.first {
        case "manifest.json" where parts.count == 1:
            return json(manifest())
        case "control":
            return control(parts.dropFirst().first, request)
        case "files" where parts.count == 2:
            guard let fixture = fixtures[parts[1]] else { return text(404, "no such file") }
            return serve(fixture, store.take(for: fixture.name), request)
        case "s" where parts.count == 3:
            guard let scenario = Scenario(rawValue: parts[1]) else { return text(404, "no such scenario") }
            guard let fixture = fixtures[parts[2]] else { return text(404, "no such file") }
            return serve(fixture, scenario, request)
        default:
            return text(404, "not found")
        }
    }

    // MARK: Control

    private func control(_ action: String?, _ request: HTTPRequest) -> ResponsePlan {
        switch action {
        case "scenarios":
            return json(Scenario.allCases.map { ["name": $0.rawValue, "summary": $0.summary] })
        case "state":
            return json(stateDescription())
        case "set":
            guard let file = request.query["file"], fixtures[file] != nil else { return text(400, "file must name a fixture") }
            guard let scenario = request.query["scenario"].flatMap(Scenario.init(rawValue:)) else { return text(400, "unknown scenario") }
            let times = request.query["times"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            store.set(scenario, for: file, times: times)
            return json(stateDescription())
        case "clear":
            store.clear(request.query["file"].flatMap { $0.isEmpty ? nil : $0 })
            return json(stateDescription())
        default:
            return text(404, "unknown control action")
        }
    }

    private func stateDescription() -> [[String: String]] {
        store.snapshot().sorted { $0.key < $1.key }.map { file, entry in
            ["file": file, "scenario": entry.scenario.rawValue, "remaining": entry.remaining.map(String.init) ?? "until cleared"]
        }
    }

    private func manifest() -> [String: Any] {
        [
            "files": order.compactMap { fixtures[$0] }.map { fixture in
                ["name": fixture.name, "contentType": fixture.contentType, "length": fixture.data.count, "sha256": fixture.sha256, "parameters": fixture.parameters] as [String: Any]
            },
            "scenarios": Scenario.allCases.map(\.rawValue),
        ]
    }

    // MARK: Files

    func serve(_ fixture: Fixture, _ scenario: Scenario, _ request: HTTPRequest) -> ResponsePlan {
        let data = fixture.data
        var base: [(String, String)] = [
            ("Content-Type", fixture.contentType),
            ("ETag", fixture.etag),
            ("Last-Modified", Self.lastModified),
            ("Accept-Ranges", "bytes"),
            ("Cache-Control", "no-store"),
        ]
        let range = request.headers["range"]

        switch scenario {
        case .ok:
            return ranged(data, base, request, rate: defaultRate)
        case .slowFirstByte:
            var plan = ranged(data, base, request, rate: defaultRate)
            plan.delay = 8
            return plan
        case .slowBody:
            return ranged(data, base, request, rate: 65_536)
        case .ignoreRange:
            base[3] = ("Accept-Ranges", "none")
            return full(data, base, rate: defaultRate)
        case .rangeNotSatisfiable:
            guard range != nil else { return full(data, base, rate: defaultRate) }
            return ResponsePlan(status: 416, headers: [("Content-Range", "bytes */\(data.count)"), ("Content-Length", "0")], body: Data())
        case .changingETag:
            let generation = store.nextETagGeneration()
            base[1] = ("ETag", "\"" + fixture.sha256.prefix(12) + "-g\(generation)\"")
            base[2] = ("Last-Modified", Self.httpDate(Date(timeIntervalSince1970: 1_791_158_400 + Double(generation))))
            if let range, let bounds = Self.parseRange(range, size: data.count) {
                return partial(data, bounds, base, rate: defaultRate)
            }
            return full(data, base, rate: defaultRate)
        case .redirect:
            let host = request.headers["host"] ?? "localhost"
            return ResponsePlan(status: 302, headers: [("Location", "http://\(host)/files/\(fixture.name)"), ("Content-Length", "0")], body: Data())
        case .noLength:
            var plan = full(data, base, rate: defaultRate)
            plan.headers.removeAll { $0.0 == "Content-Length" }
            plan.headers.append(("Connection", "close"))
            return plan
        case .disconnect:
            var plan = full(data, base, rate: defaultRate)
            plan.sendLimit = data.count * 40 / 100
            plan.resetAfterSend = true
            return plan
        case .truncated:
            var plan = full(data, base, rate: defaultRate)
            plan.sendLimit = max(0, data.count - 1_024)
            return plan
        case .notFound:
            return text(404, "not found")
        case .serverError:
            var plan = text(500, "server error")
            plan.headers.append(("Retry-After", "3"))
            return plan
        case .unavailable:
            var plan = text(503, "unavailable")
            plan.headers.append(("Retry-After", "10"))
            return plan
        case .html:
            return ResponsePlan(status: 200, headers: [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", "\(Self.htmlPage.count)")], body: Self.htmlPage)
        case .htmlAsMedia:
            return ResponsePlan(status: 200, headers: [("Content-Type", fixture.contentType), ("Content-Length", "\(Self.htmlPage.count)")], body: Self.htmlPage)
        case .checksumMismatch:
            var altered = data
            altered[altered.startIndex + data.count / 2] ^= 0xFF
            return full(altered, base, rate: defaultRate)
        case .expired:
            return text(403, "link expired")
        case .unauthorized:
            return text(401, "unauthorized")
        }
    }

    private func ranged(_ data: Data, _ base: [(String, String)], _ request: HTTPRequest, rate: Int?) -> ResponsePlan {
        guard let range = request.headers["range"] else { return full(data, base, rate: rate) }
        if let ifRange = request.headers["if-range"],
           ifRange != base.first(where: { $0.0 == "ETag" })?.1,
           ifRange != base.first(where: { $0.0 == "Last-Modified" })?.1 {
            return full(data, base, rate: rate)
        }
        guard let bounds = Self.parseRange(range, size: data.count) else {
            return ResponsePlan(status: 416, headers: [("Content-Range", "bytes */\(data.count)"), ("Content-Length", "0")], body: Data())
        }
        return partial(data, bounds, base, rate: rate)
    }

    private func full(_ data: Data, _ base: [(String, String)], rate: Int?) -> ResponsePlan {
        ResponsePlan(status: 200, headers: base + [("Content-Length", "\(data.count)")], body: data, bytesPerSecond: rate)
    }

    private func partial(_ data: Data, _ bounds: ClosedRange<Int>, _ base: [(String, String)], rate: Int?) -> ResponsePlan {
        let slice = data.subdata(in: (data.startIndex + bounds.lowerBound)..<(data.startIndex + bounds.upperBound + 1))
        return ResponsePlan(status: 206, headers: base + [
            ("Content-Range", "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(data.count)"),
            ("Content-Length", "\(slice.count)"),
        ], body: slice, bytesPerSecond: rate)
    }

    /// One `bytes=` range, or `nil` when it cannot be satisfied or is malformed.
    static func parseRange(_ header: String, size: Int) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash], last = spec[spec.index(after: dash)...]
        if first.isEmpty {
            guard let suffix = Int(last), suffix > 0 else { return nil }
            return max(0, size - suffix)...(size - 1)
        }
        guard let start = Int(first), start < size else { return nil }
        let end = last.isEmpty ? size - 1 : min(size - 1, Int(last) ?? -1)
        guard end >= start else { return nil }
        return start...end
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private func text(_ status: Int, _ message: String) -> ResponsePlan {
        let body = Data((message + "\n").utf8)
        return ResponsePlan(status: status, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", "\(body.count)")], body: body)
    }

    private func json(_ object: Any) -> ResponsePlan {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return ResponsePlan(status: 200, headers: [("Content-Type", "application/json"), ("Content-Length", "\(body.count)"), ("Cache-Control", "no-store")], body: body)
    }
}
