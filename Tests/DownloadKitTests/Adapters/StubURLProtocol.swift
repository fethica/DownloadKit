//
//  StubURLProtocol.swift
//  DownloadKitTests
//
//  A deterministic HTTP fixture served through URLProtocol to a foreground URLSession. The
//  route is the URL path, so the protocol holds no state. It proves request/response handling
//  in this process only, never a background session in the system transfer service.
//

import Foundation
@testable import DownloadKit

/// Holds the `/slow` route before its first byte until the test signals it.
let slowFirstByteGate = DispatchSemaphore(value: 0)
/// Signalled by the `/slow` route when its request arrived.
let slowRequestArrived = DispatchSemaphore(value: 0)

/// Consumes one arrival of a `/slow` request without waiting.
func slowRequestHasArrived() -> Bool {
    slowRequestArrived.wait(timeout: .now()) == .success
}

enum StubRoute {
    static let host = "stub.test"

    static func url(_ path: String, size: Int = 4_096) -> URL {
        URL(string: "https://\(host)\(path)?size=\(size)")!
    }

    /// The body every successful route serves for `size`.
    static func body(size: Int) -> Data {
        mediaBytes(size)
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == StubRoute.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value.flatMap(Int.init) ?? 4_096
        let body = StubRoute.body(size: size)
        let media = ["Content-Type": "audio/mpeg", "ETag": "\"v1\"", "Last-Modified": "Mon, 05 Oct 2026 10:00:00 GMT"]

        func respond(_ status: Int, _ headers: [String: String], _ data: Data, finish: Bool = true) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Several chunks, so progress is reported more than once.
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + 65_536)
                client.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
            }
            if finish { client.urlProtocolDidFinishLoading(self) }
        }

        let html = Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)
        switch url.path {
        case "/ok":
            respond(200, media.merging(["Content-Length": "\(size)"]) { $1 }, body)
        case "/no-length":
            respond(200, media, body)
        case "/redirect":
            let target = StubRoute.url("/ok", size: size)
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case "/slow":
            slowRequestArrived.signal()
            _ = slowFirstByteGate.wait(timeout: .now() + 10)
            respond(200, media.merging(["Content-Length": "\(size)"]) { $1 }, body)
        case "/disconnect":
            respond(200, media.merging(["Content-Length": "\(size)"]) { $1 }, body.prefix(size / 2), finish: false)
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case "/truncated":
            respond(200, media.merging(["Content-Length": "\(size)"]) { $1 }, body.prefix(size / 2))
        case "/missing":
            respond(404, ["Content-Type": "text/html", "Content-Length": "\(html.count)"], html)
        case "/unavailable":
            respond(503, ["Content-Type": "text/plain", "Retry-After": "120"], Data("busy".utf8))
        case "/error":
            respond(500, ["Content-Type": "text/plain", "Retry-After": "7"], Data("oops".utf8))
        case "/html":
            respond(200, ["Content-Type": "text/html; charset=utf-8", "Content-Length": "\(html.count)"], html)
        case "/html-as-audio":
            respond(200, ["Content-Type": "audio/mpeg", "Content-Length": "\(html.count)"], html)
        case "/expired":
            respond(403, ["Content-Type": "application/xml"], Data("<Error>expired</Error>".utf8))
        case "/unauthorized":
            respond(401, ["Content-Type": "text/plain"], Data("no".utf8))
        case "/partial":
            respond(206, media.merging(["Content-Range": "bytes 0-\(size - 1)/\(size * 2)", "Content-Length": "\(size)"]) { $1 }, body)
        case "/range-not-satisfiable":
            respond(416, ["Content-Range": "bytes */\(size)"], Data())
        case "/changed":
            respond(200, ["Content-Type": "audio/mpeg", "ETag": "\"v2\"", "Content-Length": "\(size)"], mediaBytes(size, seed: 99))
        default:
            respond(404, [:], Data())
        }
    }
}

/// Collects a session's events and waits for conditions on them.
actor EventRecorder {
    private(set) var events: [TransferSessionEvent] = []
    private var waiters: [UUID: (condition: @Sendable ([TransferSessionEvent]) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = [:]

    func append(_ event: TransferSessionEvent) {
        events.append(event)
        for (id, waiter) in waiters where waiter.condition(events) {
            waiters[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    /// Waits until `condition` holds, failing after `timeout` seconds of real time. Real time is
    /// unavoidable here: the transfer runs on URLSession's own threads.
    func wait(timeout: TimeInterval = 10, _ condition: @escaping @Sendable ([TransferSessionEvent]) -> Bool) async -> Bool {
        if condition(events) { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (condition, continuation)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    var transferEvents: [TransferEvent] {
        events.compactMap { if case .transfer(let event) = $0.payload { return event } else { return nil } }
    }

    var terminalEvents: [TransferEvent] {
        transferEvents.filter(\.isTerminal)
    }

    static func record(_ session: any TransferSession) -> EventRecorder {
        let recorder = EventRecorder()
        let events = session.events
        Task {
            for await event in events { await recorder.append(event) }
        }
        return recorder
    }
}

extension Array where Element == TransferSessionEvent {
    var hasBacklogMarker: Bool {
        contains { $0.payload == .backlogDelivered }
    }

    var terminalCount: Int {
        filter { if case .transfer(let event) = $0.payload { return event.isTerminal } else { return false } }.count
    }
}

extension URLSessionTransport {
    /// A foreground transport whose session is served by ``StubURLProtocol``.
    static func stubbed(sessionNetworkAccess: NetworkPolicy = .default, now: @escaping @Sendable () -> Date = { referenceDate }) -> URLSessionTransport {
        URLSessionTransport(options: Options(sessionNetworkAccess: sessionNetworkAccess, now: now, configure: { configuration in
            configuration.protocolClasses = [StubURLProtocol.self]
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 15
        }))
    }
}
