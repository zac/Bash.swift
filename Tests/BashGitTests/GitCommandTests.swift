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

    @Test("status -sb and branch inspection")
    func statusShortBranchAndBranchInspection() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("git init")
        _ = await session.run("printf 'one\\n' > tracked.txt")
        _ = await session.run("git add tracked.txt")
        _ = await session.run("printf 'two\\n' > tracked.txt")
        _ = await session.run("printf 'new\\n' > untracked.txt")

        let status = await session.run("git status -sb")
        #expect(status.exitCode == 0)
        #expect(status.stdoutString.contains("## "))
        #expect(status.stdoutString.contains("tracked.txt"))
        #expect(status.stdoutString.contains("untracked.txt"))

        let branch = await session.run("git branch --show-current")
        #expect(branch.exitCode == 0)
        #expect(!branch.stdoutString.isEmpty)

        let revParse = await session.run("git rev-parse --abbrev-ref HEAD")
        #expect(revParse.exitCode == 0)
        #expect(revParse.stdoutString == branch.stdoutString)
    }

    @Test("diff stat and name-only inspect worktree changes")
    func diffStatAndNameOnlyInspectWorktreeChanges() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("git init")
        _ = await session.run("git config user.email eval@example.com")
        _ = await session.run("git config user.name Eval")
        _ = await session.run("printf 'alpha\\n' > README.md")
        _ = await session.run("git add README.md")
        _ = await session.run("git commit -m \"init\"")
        _ = await session.run("printf 'beta\\n' >> README.md")

        let stat = await session.run("git diff --stat")
        #expect(stat.exitCode == 0)
        #expect(stat.stdoutString.contains("README.md"))
        #expect(stat.stdoutString.contains("1 insertion(+)"))

        let names = await session.run("git diff --name-only")
        #expect(names.exitCode == 0)
        #expect(names.stdoutString == "README.md\n")
    }

    @Test("show --stat and remote -v work for cloned repositories")
    func showStatAndRemoteVerboseWorkForClonedRepositories() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("mkdir seed")
        _ = await session.run("cd seed")
        _ = await session.run("git init")
        _ = await session.run("git config user.email eval@example.com")
        _ = await session.run("git config user.name Eval")
        _ = await session.run("echo hello > README.md")
        _ = await session.run("git add README.md")
        _ = await session.run("git commit -m \"seed\"")
        _ = await session.run("cd ..")

        let clone = await session.run("git clone seed cloned")
        #expect(clone.exitCode == 0)

        _ = await session.run("cd cloned")

        let remote = await session.run("git remote -v")
        #expect(remote.exitCode == 0)
        #expect(remote.stdoutString.contains("origin"))
        #expect(remote.stdoutString.contains("(fetch)"))
        #expect(remote.stdoutString.contains("(push)"))

        let show = await session.run("git show --stat")
        #expect(show.exitCode == 0)
        #expect(show.stdoutString.contains("seed"))
        #expect(show.stdoutString.contains("README.md"))
        #expect(show.stdoutString.contains("1 insertion(+)"))
    }

    @Test("config persists locally and drives commit identity")
    func configPersistsAndDrivesCommitIdentity() async throws {
        let (session, root) = try await GitTestSupport.makeReadWriteSession()
        defer { GitTestSupport.removeDirectory(root) }

        _ = await session.run("git init")

        let setEmail = await session.run("git config user.email eval@example.com")
        #expect(setEmail.exitCode == 0)

        let setName = await session.run("git config user.name Eval")
        #expect(setName.exitCode == 0)

        let getEmail = await session.run("git config user.email")
        #expect(getEmail.exitCode == 0)
        #expect(getEmail.stdoutString == "eval@example.com\n")

        let getName = await session.run("git config user.name")
        #expect(getName.exitCode == 0)
        #expect(getName.stdoutString == "Eval\n")

        _ = await session.run("printf 'hello\\n' > note.txt")
        _ = await session.run("git add note.txt")

        let commit = await session.run("git commit -m \"configured\"")
        #expect(commit.exitCode == 0)

        let log = await session.run("git log -n 1")
        #expect(log.exitCode == 0)
        #expect(log.stdoutString.contains("Author: Eval <eval@example.com>"))
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
            networkPolicy: ShellNetworkPolicy(
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
            networkPolicy: ShellNetworkPolicy(
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
