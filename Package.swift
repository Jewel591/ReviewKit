// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReviewKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ReviewKit", targets: ["ReviewKit"])
    ],
    targets: [
        .target(name: "ReviewKit"),
        .testTarget(name: "ReviewKitTests", dependencies: ["ReviewKit"]),
    ]
)
