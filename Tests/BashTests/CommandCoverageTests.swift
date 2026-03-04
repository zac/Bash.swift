import Foundation
import Testing
@testable import Bash

@Suite("Command Coverage")
struct CommandCoverageTests {
    private let commands = [
        "cat", "cp", "ln", "ls", "mkdir", "mv", "readlink", "rm", "rmdir", "stat", "touch", "chmod", "file", "tree", "diff",
        "grep", "egrep", "fgrep", "rg", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "awk", "sed", "xargs", "printf", "base64", "sha256sum", "sha1sum", "md5sum",
        "gzip", "gunzip", "zcat", "zip", "unzip", "tar",
        "jq", "yq", "xan",
        "basename", "cd", "dirname", "du", "echo", "env", "export", "find", "printenv", "pwd", "tee",
        "curl", "wget", "html-to-markdown", "clear", "date", "hostname", "false", "whoami", "help", "history", "jobs", "fg", "wait", "ps", "kill", "seq", "sleep", "time", "timeout", "true", "which",
    ]

    @Test("all builtins support --help")
    func allBuiltinsSupportHelp() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        for command in commands {
            let result = await session.run("\(command) --help")
            #expect(result.exitCode == 0, "\(command) --help should exit 0")
            #expect(
                !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(command) --help should emit stdout"
            )
            #expect(result.stdoutString.contains("USAGE:"), "\(command) --help should include USAGE")
        }
    }

    @Test("all builtins support -h")
    func allBuiltinsSupportShortHelp() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        for command in commands {
            let result = await session.run("\(command) -h")
            #expect(result.exitCode == 0, "\(command) -h should exit 0")
            #expect(
                !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(command) -h should emit stdout"
            )
            #expect(result.stdoutString.contains("USAGE:"), "\(command) -h should include USAGE")
        }
    }

    @Test("all builtins fail on invalid flags")
    func allBuiltinsReturnNonZeroOnInvalidFlag() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        for command in commands where command != "clear" {
            let result = await session.run("\(command) --definitely-invalid-flag")
            #expect(result.exitCode != 0, "\(command) invalid flag should fail")
            #expect(!result.stderrString.isEmpty, "\(command) invalid flag should write stderr")
        }
    }

    @Test("help output snapshot shape")
    func helpOutputSnapshotShape() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let help = await session.run("help")
        #expect(help.exitCode == 0)

        let lines = help.stdoutString
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.contains("ls"))
        #expect(lines.contains("grep"))
        #expect(lines.contains("touch"))
    }

    @Test("help verbose output includes command overviews")
    func helpVerboseOutputIncludesOverviews() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let help = await session.run("help --verbose")
        #expect(help.exitCode == 0)

        let lines = help.stdoutString
            .split(separator: "\n")
            .map(String.init)

        #expect(lines.contains(where: { $0.hasPrefix("ls") && $0.contains("List directory contents") }))
        #expect(lines.contains(where: { $0.hasPrefix("grep") && $0.contains("Print lines matching a pattern") }))
        #expect(lines.contains(where: { $0.hasPrefix("touch") && $0.contains("Change file timestamps or create empty files") }))
    }

    @Test("find and ls formatting snapshots")
    func findAndLsFormattingSnapshots() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p src/nested")
        _ = await session.run("touch src/a.txt src/nested/b.txt")

        let ls = await session.run("ls src")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString == "a.txt nested\n")

        let find = await session.run("find src")
        #expect(find.exitCode == 0)
        #expect(
            find.stdoutString ==
                "/home/user/src\n/home/user/src/a.txt\n/home/user/src/nested\n/home/user/src/nested/b.txt\n"
        )
    }
}
