// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DownloadKit",
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
            dependencies: ["DownloadKit"]),
        .testTarget(
            name: "DownloadKitTests",
            dependencies: ["DownloadKit"]),
        .testTarget(
            name: "DownloadKitUITests",
            dependencies: ["DownloadKitUI"]),
    ],
    swiftLanguageModes: [.v6]
)
