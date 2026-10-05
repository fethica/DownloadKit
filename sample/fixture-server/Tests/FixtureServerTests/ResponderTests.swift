//
//  ResponderTests.swift
//  FixtureServerTests
//

import XCTest
@testable import FixtureServer

final class ResponderTests: XCTestCase {
    private let tone = FixtureGenerator.tone("tone-a.wav", frequency: 440, seconds: 3)

    private func responder(_ store: OverrideStore = OverrideStore()) -> Responder {
        Responder(fixtures: [tone], store: store, defaultRate: nil)
    }

    private func get(_ target: String, _ headers: [String: String] = [:], _ responder: Responder? = nil) -> ResponsePlan {
        (responder ?? self.responder()).plan(for: HTTPRequest(method: "GET", target: target, headers: headers))
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data(repeating: 0x61, count: 1_000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testToneIsACanonicalWave() {
        XCTAssertEqual(tone.data.count, 44 + 22_050 * 3 * 2)
        XCTAssertEqual(tone.data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(tone.data[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(tone.data[36..<40], Data("data".utf8))
        XCTAssertEqual(tone.sha256, FixtureGenerator.tone("tone-a.wav", frequency: 440, seconds: 3).sha256, "deterministic")
    }

    func testRecordedDigestsMatchTheGenerator() {
        for fixture in FixtureGenerator.all() {
            XCTAssertEqual(FixtureGenerator.recordedDigests[fixture.name], fixture.sha256, fixture.name)
        }
    }

    func testRangesAndValidators() {
        let size = tone.data.count
        XCTAssertEqual(Responder.parseRange("bytes=0-", size: size), 0...(size - 1))
        XCTAssertEqual(Responder.parseRange("bytes=10-19", size: size), 10...19)
        XCTAssertEqual(Responder.parseRange("bytes=-100", size: size), (size - 100)...(size - 1))
        XCTAssertNil(Responder.parseRange("bytes=\(size)-", size: size))
        XCTAssertNil(Responder.parseRange("bytes=0-1,4-5", size: size))
        XCTAssertNil(Responder.parseRange("items=0-1", size: size))

        let partial = get("/files/tone-a.wav", ["Range": "bytes=100-", "If-Range": tone.etag])
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.header("Content-Range"), "bytes 100-\(size - 1)/\(size)")
        XCTAssertEqual(partial.body, tone.data.subdata(in: 100..<size))
        XCTAssertEqual(get("/files/tone-a.wav", ["Range": "bytes=100-", "If-Range": "\"other\""]).status, 200, "a stale If-Range gets the whole file")
        XCTAssertEqual(get("/files/tone-a.wav", ["Range": "bytes=\(size)-"]).status, 416)
        XCTAssertEqual(get("/files/tone-a.wav").header("Content-Length"), "\(size)")
    }

    func testEveryScenario() {
        let size = tone.data.count
        let shared = responder()
        func scenario(_ name: Scenario, _ headers: [String: String] = [:]) -> ResponsePlan {
            get("/s/\(name.rawValue)/tone-a.wav", headers, shared)
        }
        XCTAssertEqual(scenario(.ok).status, 200)
        XCTAssertEqual(scenario(.ignoreRange, ["Range": "bytes=10-"]).status, 200)
        XCTAssertEqual(scenario(.rangeNotSatisfiable, ["Range": "bytes=10-"]).status, 416)
        XCTAssertEqual(scenario(.rangeNotSatisfiable).status, 200)
        let first = scenario(.changingETag, ["Range": "bytes=10-"])
        let second = scenario(.changingETag, ["Range": "bytes=10-"])
        XCTAssertEqual(first.status, 206)
        XCTAssertNotEqual(first.header("ETag"), second.header("ETag"))
        XCTAssertNotEqual(first.header("ETag"), tone.etag)
        let redirect = get("/s/redirect/tone-a.wav", ["Host": "10.0.0.2:8080"])
        XCTAssertEqual(redirect.status, 302)
        XCTAssertEqual(redirect.header("Location"), "http://10.0.0.2:8080/files/tone-a.wav")
        XCTAssertNil(scenario(.noLength).header("Content-Length"))
        XCTAssertEqual(scenario(.slowFirstByte).delay, 8)
        XCTAssertEqual(scenario(.slowBody).bytesPerSecond, 65_536)
        let disconnect = scenario(.disconnect)
        XCTAssertEqual(disconnect.header("Content-Length"), "\(size)")
        XCTAssertEqual(disconnect.sendLimit, size * 40 / 100)
        XCTAssertTrue(disconnect.resetAfterSend)
        let truncated = scenario(.truncated)
        XCTAssertEqual(truncated.sendLimit, size - 1_024)
        XCTAssertFalse(truncated.resetAfterSend)
        XCTAssertEqual(scenario(.notFound).status, 404)
        XCTAssertEqual(scenario(.serverError).header("Retry-After"), "3")
        XCTAssertEqual(scenario(.unavailable).status, 503)
        XCTAssertEqual(scenario(.unavailable).header("Retry-After"), "10")
        XCTAssertEqual(scenario(.html).header("Content-Type"), "text/html; charset=utf-8")
        let masquerade = scenario(.htmlAsMedia)
        XCTAssertEqual(masquerade.header("Content-Type"), "audio/wav")
        XCTAssertTrue(String(decoding: masquerade.body, as: UTF8.self).hasPrefix("<!DOCTYPE html>"))
        let mismatch = scenario(.checksumMismatch)
        XCTAssertEqual(mismatch.body.count, size)
        XCTAssertNotEqual(SHA256.hex(mismatch.body), tone.sha256)
        XCTAssertEqual(scenario(.expired).status, 403)
        XCTAssertEqual(scenario(.unauthorized).status, 401)
        XCTAssertEqual(get("/s/nonsense/tone-a.wav").status, 404)
        XCTAssertEqual(get("/files/nothing.wav").status, 404)
    }

    func testControlOverridesAreCountedAndCleared() {
        let store = OverrideStore()
        let responder = responder(store)
        XCTAssertEqual(get("/control/set?file=tone-a.wav&scenario=server-error&times=2", [:], responder).status, 200)
        XCTAssertEqual(get("/files/tone-a.wav", [:], responder).status, 500)
        XCTAssertEqual(get("/files/tone-a.wav", [:], responder).status, 500)
        XCTAssertEqual(get("/files/tone-a.wav", [:], responder).status, 200, "used up")

        let post = responder.plan(for: HTTPRequest(method: "POST", target: "/control/set", headers: [:], body: Data("file=tone-a.wav&scenario=not-found".utf8)))
        XCTAssertEqual(post.status, 200)
        XCTAssertEqual(get("/files/tone-a.wav", [:], responder).status, 404)
        XCTAssertEqual(get("/files/tone-a.wav", [:], responder).status, 404, "until cleared")
        XCTAssertEqual(get("/control/clear", [:], responder).status, 200)
        XCTAssertEqual(get("/files/tone-a.wav", [:], responder).status, 200)

        XCTAssertEqual(get("/control/set?file=tone-a.wav&scenario=bogus", [:], responder).status, 400)
        XCTAssertEqual(get("/control/set?file=other.wav&scenario=ok", [:], responder).status, 400)
        XCTAssertEqual(get("/control/scenarios", [:], responder).status, 200)
        XCTAssertEqual(responder.plan(for: HTTPRequest(method: "DELETE", target: "/files/tone-a.wav", headers: [:])).status, 405)
    }

    func testManifestListsDigests() throws {
        let plan = get("/manifest.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.body) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["sha256"] as? String, tone.sha256)
        XCTAssertEqual((object["scenarios"] as? [String])?.count, Scenario.allCases.count)
    }
}
