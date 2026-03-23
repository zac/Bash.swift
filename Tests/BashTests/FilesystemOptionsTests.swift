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

    @Test("bash reexports workspace filesystem shims")
    func bashReexportsWorkspaceFilesystemShims() async throws {
        let workspaceFilesystem: any WorkspaceFilesystem = InMemoryFilesystem()
        let shellFilesystem: any ShellFilesystem = workspaceFilesystem
        let inMemoryFilesystem = InMemoryFilesystem()
        try await inMemoryFilesystem.writeFile(path: "/note.txt", data: Data("shim".utf8), append: false)
        await inMemoryFilesystem.reset()

        let info = FileInfo(
            path: "/note.txt",
            isDirectory: false,
            isSymbolicLink: false,
            size: 4,
            permissions: 0o644,
            modificationDate: nil
        )
        let entry = DirectoryEntry(name: "note.txt", info: info)
        let error = WorkspaceError.unsupported("shim check")

        #expect(await shellFilesystem.exists(path: "/"))
        #expect(!(await inMemoryFilesystem.exists(path: "/note.txt")))
        #expect(entry.info.path == "/note.txt")
        #expect(error.description.contains("shim check"))
    }

    @Test("overlay filesystem snapshots disk and keeps writes in memory")
    func overlayFilesystemSnapshotsDiskAndKeepsWritesInMemory() async throws {
        let root = try TestSupport.makeTempDirectory(prefix: "BashOverlay")
        defer { TestSupport.removeDirectory(root) }

        let onDisk = root.appendingPathComponent("seed.txt")
        try Data("seed".utf8).write(to: onDisk)

        let session = try await BashSession(
            options: SessionOptions(
                filesystem: try await OverlayFilesystem(rootDirectory: root),
                layout: .rootOnly
            )
        )

        let read = await session.run("cat /seed.txt")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "seed")

        let write = await session.run("printf updated > /seed.txt")
        #expect(write.exitCode == 0)

        let overlayRead = await session.run("cat /seed.txt")
        #expect(overlayRead.exitCode == 0)
        #expect(overlayRead.stdoutString == "updated")

        let diskContents = try String(contentsOf: onDisk, encoding: .utf8)
        #expect(diskContents == "seed")
    }

    @Test("mountable filesystem can combine roots and copy across mounts")
    func mountableFilesystemCanCombineRootsAndCopyAcrossMounts() async throws {
        let base = InMemoryFilesystem()
        let workspaceRoot = try TestSupport.makeTempDirectory(prefix: "BashMountWorkspace")
        defer { TestSupport.removeDirectory(workspaceRoot) }

        let docsRoot = try TestSupport.makeTempDirectory(prefix: "BashMountDocs")
        defer { TestSupport.removeDirectory(docsRoot) }
        try Data("guide".utf8).write(to: docsRoot.appendingPathComponent("guide.txt"))

        let mountable = MountableFilesystem(
            base: base,
            mounts: [
                MountableFilesystem.Mount(
                    mountPoint: "/workspace",
                    filesystem: try await OverlayFilesystem(rootDirectory: workspaceRoot)
                ),
                MountableFilesystem.Mount(
                    mountPoint: "/docs",
                    filesystem: try await OverlayFilesystem(rootDirectory: docsRoot)
                ),
            ]
        )

        let session = try await BashSession(
            options: SessionOptions(
                filesystem: mountable,
                layout: .rootOnly
            )
        )

        let top = await session.run("ls /")
        #expect(top.exitCode == 0)
        #expect(top.stdoutString.contains("workspace"))
        #expect(top.stdoutString.contains("docs"))

        let copy = await session.run("cp /docs/guide.txt /workspace/guide.txt")
        #expect(copy.exitCode == 0)

        let read = await session.run("cat /workspace/guide.txt")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "guide")

        #expect(!FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("guide.txt").path))
    }

    @Test("rootless session init rejects unconfigured read-write filesystem")
    func rootlessSessionInitRejectsUnconfiguredReadWriteFilesystem() async {
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
        } catch let error as WorkspaceError {
            #expect(error.description.contains("filesystem is not configured"))
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
        let documents = try SandboxFilesystem(root: .documents)
        #expect(await documents.exists(path: "/"))

        let caches = try SandboxFilesystem(root: .caches)
        #expect(await caches.exists(path: "/"))
    }

    @Test("sandbox app group invalid id throws unsupported")
    func sandboxAppGroupInvalidIDThrowsUnsupported() {
        do {
            _ = try SandboxFilesystem(root: .appGroup("invalid.group.\(UUID().uuidString)"))
            Issue.record("expected unsupported error")
        } catch let error as WorkspaceError {
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

        do {
            _ = try SecurityScopedFilesystem(url: tempURL)
            Issue.record("expected unsupported error")
        } catch let error as WorkspaceError {
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
        try await readWriteFS.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)

        let bookmarkData = try readWriteFS.makeBookmarkData()
        #expect(!bookmarkData.isEmpty)

        let storePrefix = "bashswift.tests.security.\(UUID().uuidString)."
        let store = UserDefaultsBookmarkStore(keyPrefix: storePrefix)
        let bookmarkID = "workspace"

        try await readWriteFS.saveBookmark(id: bookmarkID, store: store)

        let restored = try await SecurityScopedFilesystem.loadBookmark(id: bookmarkID, store: store, mode: .readWrite)
        let data = try await restored.readFile(path: "/note.txt")
        #expect(String(decoding: data, as: UTF8.self) == "hello")

        let readOnly = try SecurityScopedFilesystem(bookmarkData: bookmarkData, mode: .readOnly)

        do {
            try await readOnly.writeFile(path: "/blocked.txt", data: Data("x".utf8), append: false)
            Issue.record("expected read-only rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("filesystem is read-only"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        try await store.deleteBookmark(for: bookmarkID)
    }
    #endif
}
