//
//  main.swift
//  FixtureServer
//
//  swift run -c release fixture-server [--host 0.0.0.0] [--port 8080] [--rate 1048576] [--write DIR]
//
//  --host   address to bind (default 0.0.0.0, every interface, so a device on the LAN can
//           connect; use 127.0.0.1 for the simulator only)
//  --port   TCP port (default 8080)
//  --rate   body bytes per second for normal responses, 0 for unlimited (default 1 MiB/s)
//  --write  write the generated files and manifest.json to DIR and exit
//

import Foundation

var host = "0.0.0.0"
var port: UInt16 = 8080
var rate = 1_048_576
var writeDirectory: String?

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--host": host = arguments.next() ?? host
    case "--port": port = arguments.next().flatMap(UInt16.init) ?? port
    case "--rate": rate = arguments.next().flatMap(Int.init) ?? rate
    case "--write": writeDirectory = arguments.next()
    case "--help", "-h":
        log("usage: fixture-server [--host 0.0.0.0] [--port 8080] [--rate 1048576] [--write DIR]")
        exit(0)
    default:
        log("unknown argument \(argument); see --help")
        exit(2)
    }
}

let fixtures = FixtureGenerator.all()
var mismatches = 0
for fixture in fixtures {
    let recorded = FixtureGenerator.recordedDigests[fixture.name] ?? ""
    let note = recorded == fixture.sha256 ? "" : "  (DIFFERS from the recorded digest \(recorded.isEmpty ? "<none>" : recorded))"
    if !note.isEmpty { mismatches += 1 }
    log("\(fixture.name)  \(fixture.data.count) bytes  sha256 \(fixture.sha256)\(note)")
}
if mismatches > 0 {
    log("warning: \(mismatches) generated file(s) differ from the recorded digests; the sample's checksums will not match")
}

if let writeDirectory {
    let directory = URL(fileURLWithPath: writeDirectory, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fixture in fixtures { try fixture.data.write(to: directory.appendingPathComponent(fixture.name)) }
        let responder = Responder(fixtures: fixtures, store: OverrideStore(), defaultRate: nil)
        let manifest = responder.plan(for: HTTPRequest(method: "GET", target: "/manifest.json", headers: [:]))
        try manifest.body.write(to: directory.appendingPathComponent("manifest.json"))
        log("wrote \(fixtures.count) files and manifest.json")
        exit(0)
    } catch {
        log("could not write: \(error)")
        exit(1)
    }
}

let server = HTTPServer(responder: Responder(fixtures: fixtures, store: OverrideStore(), defaultRate: rate > 0 ? rate : nil))
log("serving on \(host):\(port); LAN addresses: \(localIPv4Addresses().joined(separator: ", "))")
log("routes: /files/<name>, /s/<scenario>/<name>, /manifest.json, /control/{scenarios,state,set,clear}")
do {
    try server.run(host: host, port: port)
} catch {
    log("error: \(error)")
    exit(1)
}
