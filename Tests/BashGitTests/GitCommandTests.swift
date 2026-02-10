import Foundation
import Testing
import BashGit
import Bash

@Suite("Git Command")
struct GitCommandTests {
    @Test("init and rev-parse work")
    func initAndRevParse() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        let initialize = await session.run("git init")
        #expect(initialize.exitCode == 0)
        #expect(initialize.stdoutString.contains("Initialized empty Git repository"))

        let revParse = await session.run("git rev-parse --is-inside-work-tree")
        #expect(revParse.exitCode == 0)
        #expect(revParse.stdoutString == "true\n")
    }

    @Test("version reports libgit2 feature flags")
    func versionReportsFeatures() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        let version = await session.run("git version")
        #expect(version.exitCode == 0)
        #expect(version.stdoutString.contains("BashGit/libgit2"))
        #expect(version.stdoutString.contains("features:"))
    }

    @Test("status add commit and log flow")
    func statusAddCommitAndLog() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("git init")
        _ = await session.run("printf \"hello\\n\" > note.txt")

        let untracked = await session.run("git status --short")
        #expect(untracked.exitCode == 0)
        #expect(untracked.stdoutString.contains("?? note.txt"))

        let add = await session.run("git add note.txt")
        #expect(add.exitCode == 0)

        let commit = await session.run("git commit -m \"initial\"")
        #expect(commit.exitCode == 0)
        #expect(commit.stdoutString.contains("initial"))

        let log = await session.run("git log --oneline -n 1")
        #expect(log.exitCode == 0)
        #expect(log.stdoutString.contains("initial"))

        let clean = await session.run("git status --short")
        #expect(clean.exitCode == 0)
        #expect(clean.stdoutString.isEmpty)
    }

    @Test("in-memory filesystem persists git metadata")
    func inMemoryPersistence() async throws {
        let session = try await GitTestSupport.makeInMemorySession()

        _ = await session.run("git init")
        _ = await session.run("printf \"a\\n\" > a.txt")
        _ = await session.run("git add -A")

        let commit = await session.run("git commit -m \"a\"")
        #expect(commit.exitCode == 0)

        let log = await session.run("git log --oneline -n 1")
        #expect(log.exitCode == 0)
        #expect(log.stdoutString.contains(" a"))
    }

    @Test("rev-parse outside repository is fatal")
    func revParseOutsideRepository() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        let result = await session.run("git rev-parse --is-inside-work-tree")
        #expect(result.exitCode == 128)
        #expect(result.stderrString.contains("not a git repository"))
    }
}
