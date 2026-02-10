import Foundation
import Testing
@testable import Bash

@Suite("Filesystem Options")
struct FilesystemOptionsTests {
    @Test("rootless session init works with InMemoryFilesystem")
    func rootlessSessionInitWorksWithInMemoryFilesystem() async throws {
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: InMemoryFilesystem(),
                layout: .unixLike,
                initialEnvironment: [:],
                enableGlobbing: true,
                maxHistory: 1_000
            )
        )

        let create = await session.run("touch rootless.txt")
        #expect(create.exitCode == 0)

        let ls = await session.run("ls")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains("rootless.txt"))
    }

    @Test("rootless session init rejects non-configurable filesystem")
    func rootlessSessionInitRejectsNonConfigurableFilesystem() async {
        do {
            _ = try await BashSession(
                options: SessionOptions(
                    filesystem: ReadWriteFilesystem(),
                    layout: .unixLike,
                    initialEnvironment: [:],
                    enableGlobbing: true,
                    maxHistory: 1_000
                )
            )
            Issue.record("expected unsupported error")
        } catch let error as ShellError {
            #expect(error.description.contains("filesystem requires rootDirectory initializer"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("sandbox temporary root read-write smoke")
    func sandboxTemporaryRootReadWriteSmoke() async throws {
        let filename = "bashswift-\(UUID().uuidString).txt"
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: SandboxFilesystem(root: .temporary),
                layout: .rootOnly,
                initialEnvironment: [:],
                enableGlobbing: true,
                maxHistory: 1_000
            )
        )

        let create = await session.run("touch \(filename)")
        #expect(create.exitCode == 0)

        let ls = await session.run("ls \(filename)")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains(filename))

        _ = await session.run("rm \(filename)")
    }

    @Test("sandbox documents and caches roots configure")
    func sandboxDocumentsAndCachesRootsConfigure() async throws {
        let documents = SandboxFilesystem(root: .documents)
        try documents.configureForSession()
        #expect(await documents.exists(path: "/"))

        let caches = SandboxFilesystem(root: .caches)
        try caches.configureForSession()
        #expect(await caches.exists(path: "/"))
    }

    @Test("sandbox app group invalid id throws unsupported")
    func sandboxAppGroupInvalidIDThrowsUnsupported() {
        let fs = SandboxFilesystem(root: .appGroup("invalid.group.\(UUID().uuidString)"))
        do {
            try fs.configureForSession()
            Issue.record("expected unsupported error")
        } catch let error as ShellError {
            #expect(error.description.contains("app group"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("bookmark store save-load-delete")
    func bookmarkStoreSaveLoadDelete() async throws {
        let prefix = "bashswift.tests.bookmark.\(UUID().uuidString)."
        let store = UserDefaultsBookmarkStore(keyPrefix: prefix)

        let id = "sample"
        let payload = Data([0x01, 0x02, 0x03])

        try await store.saveBookmark(payload, for: id)
        let loaded = try await store.loadBookmark(for: id)
        #expect(loaded == payload)

        try await store.deleteBookmark(for: id)
        let missing = try await store.loadBookmark(for: id)
        #expect(missing == nil)
    }

    #if os(tvOS) || os(watchOS)
    @Test("security-scoped filesystem unsupported on tvOS/watchOS")
    func securityScopedFilesystemUnsupportedOnUnsupportedPlatforms() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fs = try SecurityScopedFilesystem(url: tempURL)

        do {
            try fs.configureForSession()
            Issue.record("expected unsupported error")
        } catch let error as ShellError {
            #expect(error.description.contains("security-scoped URLs not supported"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
    #else
    @Test("security-scoped bookmark roundtrip and read-only enforcement")
    func securityScopedBookmarkRoundtripAndReadOnlyEnforcement() async throws {
        let root = try TestSupport.makeTempDirectory(prefix: "BashSecurityScoped")
        defer { TestSupport.removeDirectory(root) }

        let readWriteFS = try SecurityScopedFilesystem(url: root, mode: .readWrite)
        try readWriteFS.configureForSession()
        try await readWriteFS.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)

        let bookmarkData = try readWriteFS.makeBookmarkData()
        #expect(!bookmarkData.isEmpty)

        let storePrefix = "bashswift.tests.security.\(UUID().uuidString)."
        let store = UserDefaultsBookmarkStore(keyPrefix: storePrefix)
        let bookmarkID = "workspace"

        try await readWriteFS.saveBookmark(id: bookmarkID, store: store)

        let restored = try await SecurityScopedFilesystem.loadBookmark(id: bookmarkID, store: store, mode: .readWrite)
        try restored.configureForSession()
        let data = try await restored.readFile(path: "/note.txt")
        #expect(String(decoding: data, as: UTF8.self) == "hello")

        let readOnly = try SecurityScopedFilesystem(bookmarkData: bookmarkData, mode: .readOnly)
        try readOnly.configureForSession()

        do {
            try await readOnly.writeFile(path: "/blocked.txt", data: Data("x".utf8), append: false)
            Issue.record("expected read-only rejection")
        } catch let error as ShellError {
            #expect(error.description.contains("filesystem is read-only"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        try await store.deleteBookmark(for: bookmarkID)
    }
    #endif
}
