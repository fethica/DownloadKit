// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DownloadKit",
    defaultLocalization: "en",
    platforms: [
        // The macOS entry exists only so the pure model and state tests run with `swift test`.
        // It says nothing about iOS background transfer behaviour.
        .macOS(.v12),
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "DownloadKit",
            targets: ["DownloadKit"]),
        .library(
            name: "DownloadKitUI",
            targets: ["DownloadKitUI"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DownloadKit",
            dependencies: []),
        .target(
            name: "DownloadKitUI",
            dependencies: ["DownloadKit"],
            resources: [.process("Resources")]),
        .testTarget(
            name: "DownloadKitTests",
            dependencies: ["DownloadKit"]),
        .testTarget(
            name: "DownloadKitUITests",
            dependencies: ["DownloadKitUI"]),
        .testTarget(
            name: "DownloadKitPublicAPITests",
            dependencies: ["DownloadKit"]),
    ],
    swiftLanguageModes: [.v6]
)
