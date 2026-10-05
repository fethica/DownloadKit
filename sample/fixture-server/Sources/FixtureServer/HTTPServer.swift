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

    private func handle(_ fd: Int32) {
        guard let request = readRequest(fd) else {
            close(fd)
            return
        }
        let plan = responder.plan(for: request)
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
    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 32_768 { return nil }
        }
        guard let end = buffer.range(of: separator),
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buffer[end.upperBound...])
        let length = min(4_096, headers["content-length"].flatMap(Int.init) ?? 0)
        while body.count < length {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { break }
            body.append(contentsOf: chunk[0..<count])
        }
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body.prefix(length))
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
