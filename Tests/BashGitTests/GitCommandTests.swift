import Foundation
import Testing
import BashGit
import Bash

@Suite("Git Command")
struct GitCommandTests {
    @Test("help flags show git usage")
    func helpFlagsShowUsage() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        let longHelp = await session.run("git --help")
        #expect(longHelp.exitCode == 0)
        #expect(longHelp.stdoutString.contains("USAGE:"))

        let shortHelp = await session.run("git -h")
        #expect(shortHelp.exitCode == 0)
        #expect(shortHelp.stdoutString.contains("USAGE:"))
    }

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

    @Test("clone local repository")
    func cloneLocalRepository() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("mkdir seed")
        _ = await session.run("cd seed")
        _ = await session.run("git init")
        _ = await session.run("echo hello > README.md")
        _ = await session.run("git add README.md")

        let commit = await session.run("git commit -m \"seed\"")
        #expect(commit.exitCode == 0)

        _ = await session.run("cd ..")

        let clone = await session.run("git clone seed cloned")
        #expect(clone.exitCode == 0)
        #expect(clone.stderrString.contains("Cloning into 'cloned'"))

        _ = await session.run("cd cloned")

        let revParse = await session.run("git rev-parse --is-inside-work-tree")
        #expect(revParse.exitCode == 0)
        #expect(revParse.stdoutString == "true\n")

        let readme = await session.run("cat README.md")
        #expect(readme.exitCode == 0)
        #expect(readme.stdoutString == "hello\n")

        let log = await session.run("git log --oneline -n 1")
        #expect(log.exitCode == 0)
        #expect(log.stdoutString.contains("seed"))
    }

    @Test("clone fails when destination exists")
    func cloneFailsWhenDestinationExists() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("mkdir seed")
        _ = await session.run("cd seed")
        _ = await session.run("git init")
        _ = await session.run("echo hello > README.md")
        _ = await session.run("git add README.md")

        let commit = await session.run("git commit -m \"seed\"")
        #expect(commit.exitCode == 0)

        _ = await session.run("cd ..")
        _ = await session.run("mkdir cloned")

        let clone = await session.run("git clone seed cloned")
        #expect(clone.exitCode == 1)
        #expect(clone.stderrString.contains("already exists"))
    }

    @Test("clone remote repository respects network policy")
    func cloneRemoteRepositoryRespectsNetworkPolicy() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession(
            networkPolicy: NetworkPolicy(
                allowsHTTPRequests: true,
                denyPrivateRanges: true
            )
        )
        defer { GitTestSupport.removeDirectory(root) }

        let clone = await session.run("git clone https://127.0.0.1:1/repo.git")
        #expect(clone.exitCode == 1)
        #expect(clone.stderrString.contains("private network host"))
    }

    @Test("clone ssh-style repository respects host allowlist")
    func cloneSSHStyleRepositoryRespectsHostAllowlist() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession(
            networkPolicy: NetworkPolicy(
                allowsHTTPRequests: true,
                allowedHosts: ["gitlab.com"]
            )
        )
        defer { GitTestSupport.removeDirectory(root) }

        let clone = await session.run("git clone git@github.com:velos/Bash.swift.git")
        #expect(clone.exitCode == 1)
        #expect(clone.stderrString.contains("not in the network allowlist"))
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
