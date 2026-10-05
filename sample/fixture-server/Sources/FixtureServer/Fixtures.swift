//
//  Fixtures.swift
//  FixtureServer
//
//  Deterministic generated media. Nothing is recorded or licensed: every byte comes from the
//  parameters below, so the same build always produces the same files and digests.
//
//  Tones (`tone-*.wav`): RIFF/WAVE, PCM, 16-bit signed little endian, mono, 22,050 Hz,
//  amplitude 0.5 of full scale (16,383), sample n = round(16383 * sin(2 * pi * f * n / 22050)),
//  with a 20 ms linear fade in and out. The 44-byte header is the canonical one (fmt chunk of
//  16 bytes, then data).
//    tone-a.wav   440 Hz,  3 s
//    tone-b.wav   660 Hz,  3 s
//    tone-c.wav   880 Hz,  3 s
//    long-tone.wav 220 Hz, 60 s
//
//  Synthetic file (`large.bin`): 24 MiB, the ASCII magic "DKFX" then xorshift64 output
//  (x ^= x << 13; x ^= x >> 7; x ^= x << 17; seed 0x9E3779B97F4A7C15), little endian, 8 bytes
//  per step. Served as application/octet-stream at a limited rate so progress, pause and
//  cancel are visible.
//
//  The digests are recorded in `recordedDigests` and checked at start-up.
//

import Foundation

struct Fixture: Sendable {
    let name: String
    let contentType: String
    let data: Data
    let sha256: String
    let parameters: String

    /// A strong entity tag derived from the content.
    var etag: String { "\"" + String(sha256.prefix(16)) + "\"" }
}

enum FixtureGenerator {
    /// The SHA-256 of each generated file, as recorded when the parameters were chosen. The
    /// sample app's catalog uses the same values.
    static let recordedDigests: [String: String] = [
        "tone-a.wav": "751cff056f4961db52e34a8b30075cb16ae0464c8b70190e49cf4ef847ee916e",
        "tone-b.wav": "c840066afbf14bba502be81512787a991c9f3f506df1a9522df219b4f54adb93",
        "tone-c.wav": "77b1569c744e52ce6e53ae122a1fde23c256c09bb0ea4ffdd3b14d261f216172",
        "long-tone.wav": "b8ba52028bcbe09f8888a2a56a14a74f965a37534777bbbf2b72603e103cbf31",
        "large.bin": "69e31f4f29cc93bca1b122c6ecd43f58c162700cc0d59a5f7eacfbd1e86649d8",
    ]

    static let sampleRate = 22_050
    static let amplitude = 16_383.0
    static let fadeSeconds = 0.02
    static let largeSize = 24 * 1_024 * 1_024
    static let largeSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    static func all() -> [Fixture] {
        [
            tone("tone-a.wav", frequency: 440, seconds: 3),
            tone("tone-b.wav", frequency: 660, seconds: 3),
            tone("tone-c.wav", frequency: 880, seconds: 3),
            tone("long-tone.wav", frequency: 220, seconds: 60),
            large(),
        ]
    }

    static func tone(_ name: String, frequency: Double, seconds: Int) -> Fixture {
        let count = sampleRate * seconds
        let fade = Int(Double(sampleRate) * fadeSeconds)
        var data = wavHeader(sampleCount: count)
        data.reserveCapacity(44 + count * 2)
        var samples = [UInt8](repeating: 0, count: count * 2)
        for n in 0..<count {
            var gain = 1.0
            if n < fade { gain = Double(n) / Double(fade) }
            if n >= count - fade { gain = Double(count - 1 - n) / Double(fade) }
            let value = (amplitude * gain * sin(2 * Double.pi * frequency * Double(n) / Double(sampleRate))).rounded()
            let sample = UInt16(bitPattern: Int16(value))
            samples[n * 2] = UInt8(truncatingIfNeeded: sample)
            samples[n * 2 + 1] = UInt8(truncatingIfNeeded: sample >> 8)
        }
        data.append(contentsOf: samples)
        return make(name, "audio/wav", data, "PCM 16-bit mono \(sampleRate) Hz, \(Int(frequency)) Hz sine, \(seconds) s, amplitude 16383, 20 ms fades")
    }

    static func large() -> Fixture {
        var bytes = [UInt8](repeating: 0, count: largeSize)
        bytes[0] = 0x44; bytes[1] = 0x4B; bytes[2] = 0x46; bytes[3] = 0x58  // "DKFX"
        var x = largeSeed
        var index = 4
        while index < largeSize {
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            var value = x
            for _ in 0..<8 where index < largeSize {
                bytes[index] = UInt8(truncatingIfNeeded: value)
                value >>= 8
                index += 1
            }
        }
        return make("large.bin", "application/octet-stream", Data(bytes), "24 MiB, \"DKFX\" then xorshift64 (13, 7, 17) from seed 0x9E3779B97F4A7C15, little endian")
    }

    private static func make(_ name: String, _ type: String, _ data: Data, _ parameters: String) -> Fixture {
        Fixture(name: name, contentType: type, data: data, sha256: SHA256.hex(data), parameters: parameters)
    }

    static func wavHeader(sampleCount: Int) -> Data {
        var header = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        let dataSize = UInt32(sampleCount * 2)
        header.append(contentsOf: Array("RIFF".utf8)); append32(36 + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1)                          // PCM
        append16(1)                          // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))     // byte rate
        append16(2)                          // block align
        append16(16)                         // bits per sample
        header.append(contentsOf: Array("data".utf8)); append32(dataSize)
        return header
    }
}
