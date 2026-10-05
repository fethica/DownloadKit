// swift-tools-version:6.0
// A test-only HTTP fixture server for the sample app. It is a separate package: nothing here is
// part of, or linked into, the DownloadKit library products.

import PackageDescription

let package = Package(
    name: "FixtureServer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fixture-server", targets: ["FixtureServer"]),
    ],
    targets: [
        .executableTarget(name: "FixtureServer"),
        .testTarget(name: "FixtureServerTests", dependencies: ["FixtureServer"]),
    ],
    swiftLanguageModes: [.v6]
)
