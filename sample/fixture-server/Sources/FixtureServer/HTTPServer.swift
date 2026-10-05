//
//  HTTPServer.swift
//  FixtureServer
//
//  A minimal HTTP/1.1 server on BSD sockets: one thread per connection, one request per
//  connection (`Connection: close`). Enough for deterministic fixtures, nothing more.
//

import Foundation

final class HTTPServer: Sendable {
    let responder: Responder

    init(responder: Responder) {
        self.responder = responder
    }

    /// Binds `host:port` and serves until the process ends.
    func run(host: String, port: UInt16) throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ServerError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw ServerError.address(host) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ServerError.bind(errno) }
        guard listen(listener, 64) == 0 else { throw ServerError.listen(errno) }

        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [self] in
                self.handle(client)
            }
        }
    }

    /// Answers one connection and closes it. A request that cannot be framed gets a 400 and
    /// ends only its own connection; the server keeps accepting others.
    func handle(_ fd: Int32) {
        let request: HTTPRequest
        let plan: ResponsePlan
        switch readRequest(fd) {
        case .closed:
            close(fd)
            return
        case .malformed(let reason):
            request = HTTPRequest(method: "-", target: "-", headers: [:])
            plan = ResponsePlan.text(400, "bad request: \(reason)")
        case .request(let parsed):
            request = parsed
            plan = responder.plan(for: parsed)
        }
        if plan.delay > 0 { Thread.sleep(forTimeInterval: plan.delay) }

        var head = "HTTP/1.1 \(plan.status) \(Self.reason(plan.status))\r\n"
        for (name, value) in plan.headers { head += "\(name): \(value)\r\n" }
        if plan.header("Connection") == nil { head += "Connection: close\r\n" }
        head += "\r\n"

        var sent = 0
        var ok = write(fd, Data(head.utf8))
        if ok, request.method != "HEAD" {
            let limit = min(plan.body.count, plan.sendLimit ?? plan.body.count)
            let chunk = 16_384
            while ok, sent < limit {
                let end = min(limit, sent + chunk)
                ok = write(fd, plan.body.subdata(in: (plan.body.startIndex + sent)..<(plan.body.startIndex + end)))
                if ok { sent = end }
                if let rate = plan.bytesPerSecond, rate > 0, sent < limit {
                    Thread.sleep(forTimeInterval: Double(chunk) / Double(rate))
                }
            }
        }

        let range = request.headers["range"].map { " range=\($0)" } ?? ""
        let ending = plan.resetAfterSend ? " reset" : (plan.sendLimit != nil ? " short" : "")
        log("\(request.method) \(request.path)\(range) -> \(plan.status) \(sent)/\(plan.body.count) bytes\(ending)")

        if plan.resetAfterSend {
            var abort = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
        } else {
            shutdown(fd, SHUT_WR)
        }
        close(fd)
    }

    /// Reads the request head and a small form body (control requests only).
    private func readRequest(_ fd: Int32) -> RequestRead {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            if buffer.count > RequestHead.maxHeadLength { return .malformed("request head too large") }
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return buffer.isEmpty ? .closed : .malformed("incomplete request head") }
            buffer.append(contentsOf: chunk[0..<count])
        }
        guard let end = buffer.range(of: separator) else { return .malformed("incomplete request head") }
        guard end.lowerBound - buffer.startIndex <= RequestHead.maxHeadLength else { return .malformed("request head too large") }
        let head: RequestHead
        switch RequestHead.parse(buffer[buffer.startIndex..<end.lowerBound]) {
        case .success(let parsed): head = parsed
        case .failure(let failure): return .malformed(failure.reason)
        }
        var body = Data(buffer[end.upperBound...])
        while body.count < head.contentLength {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return .malformed("body shorter than Content-Length") }
            body.append(contentsOf: chunk[0..<count])
        }
        return .request(HTTPRequest(method: head.method, target: head.target, headers: head.headers, body: body.prefix(head.contentLength)))
    }

    private func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = send(fd, pointer, remaining, 0)
                if written <= 0 { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// What reading a connection produced.
enum RequestRead {
    /// The peer closed before sending anything.
    case closed
    /// The bytes cannot be framed as one request; answered with 400.
    case malformed(String)
    case request(HTTPRequest)
}

/// A parsed request line and header block, validated before any body is read.
struct RequestHead: Equatable {
    /// The largest accepted head, request line and headers together.
    static let maxHeadLength = 32_768
    /// The largest accepted body. Only control requests carry one, a short form.
    static let maxBodyLength = 4_096

    struct Failure: Error, Equatable {
        let reason: String
    }

    var method: String
    var target: String
    /// Lowercased names.
    var headers: [String: String]
    var contentLength: Int

    /// Parses the bytes before the blank line. Rejects a request line that is not
    /// `METHOD /target HTTP/x.y`, a header line without a name, and a `Content-Length` that is
    /// not a decimal number within ``maxBodyLength`` (or that disagrees with a repeated one), and
    /// any `Transfer-Encoding`.
    static func parse(_ bytes: Data) -> Result<RequestHead, Failure> {
        guard let text = String(data: bytes, encoding: .utf8) else { return .failure(Failure(reason: "head is not UTF-8")) }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isLetter }),
              requestLine[1].hasPrefix("/"),
              requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(Failure(reason: "malformed request line"))
        }
        var headers: [String: String] = [:]
        var lengths: Set<String> = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line[..<colon].contains(where: { $0 == " " || $0 == "\t" }) else {
                return .failure(Failure(reason: "malformed header line"))
            }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { lengths.insert(value) }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .failure(Failure(reason: "Transfer-Encoding is not supported")) }
        var contentLength = 0
        if !lengths.isEmpty {
            guard lengths.count == 1, let value = lengths.first, !value.isEmpty, value.count <= 10,
                  value.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(value) else {
                return .failure(Failure(reason: "invalid Content-Length"))
            }
            guard parsed <= maxBodyLength else { return .failure(Failure(reason: "body too large")) }
            contentLength = parsed
        }
        return .success(RequestHead(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, contentLength: contentLength))
    }
}

extension ResponsePlan {
    static func text(_ status: Int, _ message: String) -> ResponsePlan {
        let body = Data((message + "\n").utf8)
        return ResponsePlan(status: status, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", "\(body.count)")], body: body)
    }
}

enum ServerError: Error, CustomStringConvertible {
    case socket(Int32), address(String), bind(Int32), listen(Int32)

    var description: String {
        switch self {
        case .socket(let code): return "socket failed (errno \(code))"
        case .address(let host): return "not an IPv4 address: \(host)"
        case .bind(let code): return "bind failed (errno \(code)); is the port in use?"
        case .listen(let code): return "listen failed (errno \(code))"
        }
    }
}

/// One line on standard output, flushed.
func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// The machine's IPv4 addresses other than loopback, for the device to connect to.
func localIPv4Addresses() -> [String] {
    var result: [String] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.hasPrefix("127.") { result.append(text) }
        }
    }
    return result
}
