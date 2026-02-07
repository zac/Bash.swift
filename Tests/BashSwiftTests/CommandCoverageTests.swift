import Foundation
import Testing
@testable import BashSwift

@Suite("Command Coverage")
struct CommandCoverageTests {
    private let commands = [
        "cat", "cp", "ln", "ls", "mkdir", "mv", "readlink", "rm", "rmdir", "stat", "touch",
        "grep", "egrep", "fgrep", "head", "tail", "wc", "sort", "uniq", "cut", "tr",
        "basename", "cd", "dirname", "du", "echo", "env", "export", "find", "printenv", "pwd", "tee",
        "clear", "date", "false", "help", "history", "seq", "sleep", "true", "which",
    ]

    @Test("all builtins support --help")
    func allBuiltinsSupportHelp() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        for command in commands {
            let result = await session.run("\(command) --help")
            #expect(result.exitCode == 0)
            #expect(!result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("all builtins fail on invalid flags")
    func allBuiltinsReturnNonZeroOnInvalidFlag() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        for command in commands where command != "clear" {
            let result = await session.run("\(command) --definitely-invalid-flag")
            #expect(result.exitCode != 0)
            #expect(!result.stderrString.isEmpty)
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
