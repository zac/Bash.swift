import Foundation
import BashGit
import Bash

enum GitTestSupport {
    static func makeTempDirectory(prefix: String = "BashGitTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeReadWriteSession(
        networkPolicy: NetworkPolicy = .unrestricted,
        permissionHandler: (@Sendable (PermissionRequest) async -> PermissionDecision)? = nil
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
        await session.registerGit()
        return (session, root)
    }

    static func makeInMemorySession(
        networkPolicy: NetworkPolicy = .unrestricted,
        permissionHandler: (@Sendable (PermissionRequest) async -> PermissionDecision)? = nil
    ) async throws -> BashSession {
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: InMemoryFilesystem(),
                layout: .unixLike,
                networkPolicy: networkPolicy,
                permissionHandler: permissionHandler
            )
        )
        await session.registerGit()
        return session
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
