// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Bash",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "Bash",
            targets: ["Bash"]
        ),
        .library(
            name: "BashSQLite",
            targets: ["BashSQLite"]
        ),
        .library(
            name: "BashPython",
            targets: ["BashPython"]
        ),
        .library(
            name: "BashGit",
            targets: ["BashGit"]
        ),
        .library(
            name: "BashSecrets",
            targets: ["BashSecrets"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/velos/Workspace.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.3"),
    ],
    targets: [
        .binaryTarget(
            name: "Clibgit2",
            url: "https://github.com/flaboy/static-libgit2/releases/download/1.8.5/Clibgit2.xcframework.zip",
            checksum: "f62a6760f8c2ff1a82e4fb80c69fe2aa068458c7619f5b98c53c71579f72f9c7"
        ),
        .binaryTarget(
            name: "CPython",
            url: "https://github.com/velos/Bash.swift/releases/download/cpython-3.13-b13/CPython.xcframework.zip",
            checksum: "5afb0b07be17ec17b3fa075fcd87294f567c7de1e1df08926239f61277c2d8db"
        ),
        .target(
            name: "Bash",
            dependencies: [
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "BashSQLite",
            dependencies: [
                "Bash",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "BashPython",
            dependencies: [
                "Bash",
                "BashCPythonBridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "BashCPythonBridge",
            dependencies: [
                .target(
                    name: "CPython",
                    condition: .when(platforms: [.macOS])
                ),
            ],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Python", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "BashGit",
            dependencies: [
                "Bash",
                "Clibgit2",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedLibrary("iconv")
            ]
        ),
        .target(
            name: "BashSecrets",
            dependencies: [
                "Bash",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "BashEvalRunner",
            dependencies: [
                "Bash",
                "BashPython",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "BashTests",
            dependencies: ["Bash"]
        ),
        .testTarget(
            name: "BashSQLiteTests",
            dependencies: [
                "Bash",
                "BashSQLite",
            ]
        ),
        .testTarget(
            name: "BashPythonTests",
            dependencies: [
                "Bash",
                "BashPython",
            ]
        ),
        .testTarget(
            name: "BashGitTests",
            dependencies: [
                "Bash",
                "BashGit",
            ]
        ),
        .testTarget(
            name: "BashSecretsTests",
            dependencies: [
                "Bash",
                "BashSecrets",
            ]
        ),
    ]
)
