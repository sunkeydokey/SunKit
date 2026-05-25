// swift-tools-version: 6.0

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
        .library(
            name: "SunKitSwiftUI",
            targets: ["SunKitSwiftUI"]
        ),
    ],
    targets: [
        .target(
            name: "SunKit",
            path: "Sources/SunKit"
        ),
        .target(
            name: "SunKitSwiftUI",
            dependencies: ["SunKit"],
            path: "Sources/SunKitSwiftUI"
        ),
        .testTarget(
            name: "SunKitTests",
            dependencies: [
                "SunKit",
                "SunKitSwiftUI",
            ],
            path: "Tests/CoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
