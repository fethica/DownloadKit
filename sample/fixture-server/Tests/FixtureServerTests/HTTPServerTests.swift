//
//  HTTPServerTests.swift
//  FixtureServerTests
//
//  Request framing: malformed heads and bodies are answered with 400 on their own connection,
//  and the same server keeps answering well-formed requests afterwards. Each connection is a
//  socket pair, so no port is opened.
//

import XCTest
@testable import FixtureServer

final class HTTPServerTests: XCTestCase {
    private let server = HTTPServer(responder: Responder(
        fixtures: [FixtureGenerator.tone("tone-a.wav", frequency: 440, seconds: 1)],
        store: OverrideStore(),
        defaultRate: nil
    ))

    /// Writes `bytes` to a fresh connection, optionally closes the writing side, lets the
    /// server answer it and returns everything the server sent.
    private func exchange(_ bytes: Data, closeAfterWriting: Bool = true) throws -> String {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        let (client, served) = (pair[0], pair[1])
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(served, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(served, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let done = expectation(description: "answered")
        let server = self.server
        Thread.detachNewThread {
            server.handle(served)
            done.fulfill()
        }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = send(client, base, raw.count, 0)
        }
        if closeAfterWriting { shutdown(client, SHUT_WR) }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { break }
            received.append(contentsOf: chunk[0..<count])
        }
        close(client)
        wait(for: [done], timeout: 10)
        return String(decoding: received, as: UTF8.self)
    }

    private func status(of response: String) -> String {
        // "\r\n" is one Character in Swift, so split on the string.
        response.components(separatedBy: "\r\n").first ?? ""
    }

    private func assertServesAWellFormedRequest(file: StaticString = #filePath, line: UInt = #line) throws {
        let response = try exchange(Data("GET /files/tone-a.wav HTTP/1.1\r\nHost: fixture\r\n\r\n".utf8))
        XCTAssertEqual(status(of: response), "HTTP/1.1 200 OK", file: file, line: line)
    }

    func testNegativeContentLengthIsRejectedAndTheServerKeepsServing() throws {
        let response = try exchange(Data("POST /control/reset HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
        XCTAssertEqual(status(of: response), "HTTP/1.1 400 Bad Request")
        XCTAssertTrue(response.contains("invalid Content-Length"))
        try assertServesAWellFormedRequest()
    }

    func testMalformedRequestsAreAnsweredWith400() throws {
        let cases: [(String, String)] = [
            ("GARBAGE\r\n\r\n", "malformed request line"),
            ("GET\r\n\r\n", "malformed request line"),
            ("GET  /files/tone-a.wav HTTP/1.1\r\n\r\n", "malformed request line"),
            ("GET files/tone-a.wav HTTP/1.1\r\n\r\n", "malformed request line"),
            ("GET /files/tone-a.wav SPDY/3\r\n\r\n", "malformed request line"),
            ("GET /files/tone-a.wav HTTP/1.1\r\nno colon here\r\n\r\n", "malformed header line"),
            ("GET /files/tone-a.wav HTTP/1.1\r\n: empty name\r\n\r\n", "malformed header line"),
            ("POST /control/reset HTTP/1.1\r\nContent-Length: ten\r\n\r\n", "invalid Content-Length"),
            ("POST /control/reset HTTP/1.1\r\nContent-Length: 1e3\r\n\r\n", "invalid Content-Length"),
            ("POST /control/reset HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n", "invalid Content-Length"),
            ("POST /control/reset HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nab", "invalid Content-Length"),
            ("POST /control/reset HTTP/1.1\r\nContent-Length: 4097\r\n\r\n", "body too large"),
            ("POST /control/reset HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "Transfer-Encoding is not supported"),
        ]
        for (request, reason) in cases {
            let response = try exchange(Data(request.utf8))
            XCTAssertEqual(status(of: response), "HTTP/1.1 400 Bad Request", request)
            XCTAssertTrue(response.contains(reason), "\(request) -> \(response)")
        }
        try assertServesAWellFormedRequest()
    }

    func testTruncatedBodyIsRejected() throws {
        let response = try exchange(Data("POST /control/reset HTTP/1.1\r\nContent-Length: 20\r\n\r\nshort".utf8))
        XCTAssertEqual(status(of: response), "HTTP/1.1 400 Bad Request")
        XCTAssertTrue(response.contains("body shorter than Content-Length"))
        try assertServesAWellFormedRequest()
    }

    func testTruncatedHeadIsRejected() throws {
        let response = try exchange(Data("GET /files/tone-a.wav HTTP/1.1\r\nHost: fix".utf8))
        XCTAssertEqual(status(of: response), "HTTP/1.1 400 Bad Request")
        XCTAssertTrue(response.contains("incomplete request head"))
        try assertServesAWellFormedRequest()
    }

    func testOversizedHeadIsRejected() throws {
        let filler = String(repeating: "a", count: RequestHead.maxHeadLength + 10)
        let response = try exchange(Data("GET /files/tone-a.wav HTTP/1.1\r\nX-Filler: \(filler)\r\n\r\n".utf8))
        XCTAssertEqual(status(of: response), "HTTP/1.1 400 Bad Request")
        XCTAssertTrue(response.contains("request head too large"))
        try assertServesAWellFormedRequest()
    }

    func testUnknownPathIs404() throws {
        let response = try exchange(Data("GET /nowhere HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(status(of: response), "HTTP/1.1 404 Not Found")
        try assertServesAWellFormedRequest()
    }

    func testEmptyConnectionIsClosedWithoutAnAnswer() throws {
        XCTAssertEqual(try exchange(Data()), "")
        try assertServesAWellFormedRequest()
    }

    func testWellFormedHeadIsParsed() {
        let head = RequestHead.parse(Data("POST /control/scenario HTTP/1.1\r\nContent-Length: 0".utf8))
        XCTAssertEqual(try head.get().contentLength, 0)
        XCTAssertEqual(try head.get().method, "POST")
        XCTAssertEqual(try head.get().target, "/control/scenario")
    }
}
