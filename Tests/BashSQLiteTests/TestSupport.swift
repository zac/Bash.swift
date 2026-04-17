import Foundation
import Bash

#if SQLite

enum SQLiteTestSupport {
    static func makeTempDirectory(prefix: String = "BashSQLiteTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeReadWriteSession() async throws -> (session: BashSession, root: URL) {
        let root = try makeTempDirectory()
        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(filesystem: ReadWriteFilesystem(), layout: .unixLike)
        )
        return (session, root)
    }

    static func makeInMemorySession() async throws -> BashSession {
        let options = SessionOptions(filesystem: InMemoryFilesystem(), layout: .unixLike)
        return try await BashSession(options: options)
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
