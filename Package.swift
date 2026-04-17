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
    ],
    traits: [
        "Git",
        "Python",
        "SQLite",
        "Secrets",
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
            name: "BashCore",
            dependencies: [
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "BashGitFeature",
            dependencies: [
                "BashCore",
                "Clibgit2",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BashGit",
            linkerSettings: [
                .linkedLibrary("iconv")
            ]
        ),
        .target(
            name: "BashPythonFeature",
            dependencies: [
                "BashCore",
                "BashCPythonBridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BashPython"
        ),
        .target(
            name: "BashCPythonBridge",
            dependencies: [
                .target(
                    name: "CPython",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
            ],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Python", .when(platforms: [.macOS, .iOS])),
            ]
        ),
        .target(
            name: "BashSQLiteFeature",
            dependencies: [
                "BashCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BashSQLite",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "BashSecretsFeature",
            dependencies: [
                "BashCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BashSecrets",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "BashTools",
            dependencies: [
                "BashCore",
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "BashGitFeature", condition: .when(traits: ["Git"])),
                .target(name: "BashPythonFeature", condition: .when(traits: ["Python"])),
                .target(name: "BashSQLiteFeature", condition: .when(traits: ["SQLite"])),
                .target(name: "BashSecretsFeature", condition: .when(traits: ["Secrets"])),
            ]
        ),
        .target(
            name: "Bash",
            dependencies: [
                "BashCore",
                "BashTools",
                .target(name: "BashGitFeature", condition: .when(traits: ["Git"])),
                .target(name: "BashPythonFeature", condition: .when(traits: ["Python"])),
                .target(name: "BashSQLiteFeature", condition: .when(traits: ["SQLite"])),
                .target(name: "BashSecretsFeature", condition: .when(traits: ["Secrets"])),
            ]
        ),
        .executableTarget(
            name: "BashEvalRunner",
            dependencies: [
                "Bash",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "BashTests",
            dependencies: [
                "Bash",
                "BashCore",
            ]
        ),
        .testTarget(
            name: "BashSQLiteTests",
            dependencies: ["Bash"]
        ),
        .testTarget(
            name: "BashPythonTests",
            dependencies: ["Bash"]
        ),
        .testTarget(
            name: "BashGitTests",
            dependencies: ["Bash"]
        ),
        .testTarget(
            name: "BashSecretsTests",
            dependencies: ["Bash"]
        ),
    ]
)
