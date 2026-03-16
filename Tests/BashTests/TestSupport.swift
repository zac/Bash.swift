import Foundation
@testable import Bash

enum TestSupport {
    static func makeTempDirectory(prefix: String = "BashTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSession(
        filesystem: (any ShellFilesystem)? = nil,
        layout: SessionLayout = .unixLike,
        enableGlobbing: Bool = true,
        networkPolicy: NetworkPolicy = .unrestricted,
        permissionHandler: (@Sendable (PermissionRequest) async -> PermissionDecision)? = nil
    ) async throws -> (session: BashSession, root: URL) {
        let root = try makeTempDirectory()
        let options = SessionOptions(
            filesystem: filesystem ?? ReadWriteFilesystem(),
            layout: layout,
            initialEnvironment: [:],
            enableGlobbing: enableGlobbing,
            maxHistory: 1_000,
            networkPolicy: networkPolicy,
            permissionHandler: permissionHandler
        )

        let session = try await BashSession(rootDirectory: root, options: options)
        return (session, root)
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
