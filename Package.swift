// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BashSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "BashSwift",
            targets: ["BashSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "BashSwift",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "BashSwiftTests",
            dependencies: ["BashSwift"]
        ),
    ]
)
