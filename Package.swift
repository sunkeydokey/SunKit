// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SunKit",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "SunKit",
            targets: ["SunKit"]
        ),
    ],
    targets: [
        .target(
            name: "SunKit",
            path: "Sources"
        ),
        .testTarget(
            name: "SunKitTests",
            dependencies: ["SunKit"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
