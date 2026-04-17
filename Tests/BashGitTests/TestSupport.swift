import Foundation
import Bash

#if Git

enum GitTestSupport {
    static func makeTempDirectory(prefix: String = "BashGitTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeReadWriteSession(
        networkPolicy: ShellNetworkPolicy = .unrestricted,
        permissionHandler: (@Sendable (ShellPermissionRequest) async -> ShellPermissionDecision)? = nil
    ) async throws -> (session: BashSession, root: URL) {
        let root = try makeTempDirectory()
        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(
                filesystem: ReadWriteFilesystem(),
                layout: .unixLike,
                networkPolicy: networkPolicy,
                permissionHandler: permissionHandler
            )
        )
        return (session, root)
    }

    static func makeInMemorySession(
        networkPolicy: ShellNetworkPolicy = .unrestricted,
        permissionHandler: (@Sendable (ShellPermissionRequest) async -> ShellPermissionDecision)? = nil
    ) async throws -> BashSession {
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: InMemoryFilesystem(),
                layout: .unixLike,
                networkPolicy: networkPolicy,
                permissionHandler: permissionHandler
            )
        )
        return session
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
