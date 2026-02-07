import Foundation
import Testing
@testable import BashSwift

@Suite("Session Integration")
struct SessionIntegrationTests {
    @Test("touch then ls mutates filesystem")
    func touchThenLsShowsFileAndMutatesRealFilesystem() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let touch = await session.run("touch file.txt")
        #expect(touch.exitCode == 0)

        let ls = await session.run("ls")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains("file.txt"))

        let physicalPath = root
            .appendingPathComponent("home/user", isDirectory: true)
            .appendingPathComponent("file.txt")
            .path
        #expect(FileManager.default.fileExists(atPath: physicalPath))
    }

    @Test("pipe and output redirection")
    func pipeAndOutputRedirection() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let exec = await session.run("echo hi | tee out.txt > copy.txt")
        #expect(exec.exitCode == 0)
        #expect(exec.stdoutString == "")

        let out = await session.run("cat out.txt")
        #expect(out.stdoutString == "hi\n")

        let copy = await session.run("cat copy.txt")
        #expect(copy.stdoutString == "hi\n")
    }

    @Test("export and variable expansion")
    func exportAndVariableExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let exported = await session.run("export A=1")
        #expect(exported.exitCode == 0)

        let echoed = await session.run("echo $A")
        #expect(echoed.stdoutString == "1\n")

        let fallback = await session.run("echo ${MISSING:-fallback}")
        #expect(fallback.stdoutString == "fallback\n")
    }

    @Test("cd and pwd with semicolon chaining")
    func cdPwdAndSemicolonChaining() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("mkdir a; cd a; pwd")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "/home/user/a\n")

        let cwd = await session.currentDirectory
        #expect(cwd == "/home/user/a")
    }

    @Test("and/or short-circuiting")
    func andOrShortCircuiting() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("false && echo no; true || echo no; true && echo yes; false || echo ok")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "yes\nok\n")
    }

    @Test("unknown command returns 127")
    func unknownCommandReturns127() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("not-a-real-command")
        #expect(result.exitCode == 127)
        #expect(result.stderrString.contains("command not found"))
    }

    @Test("stderr redirection and merge")
    func stderrRedirectionAndStderrToStdoutMerge() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let redir = await session.run("ls does-not-exist 2> err.txt")
        #expect(redir.exitCode != 0)
        #expect(redir.stderrString == "")

        let err = await session.run("cat err.txt")
        #expect(err.stdoutString.contains("does-not-exist"))

        let merged = await session.run("ls does-not-exist 2>&1")
        #expect(merged.exitCode != 0)
        #expect(merged.stdoutString.contains("does-not-exist"))
        #expect(merged.stderrString == "")
    }

    @Test("stdin redirection")
    func inputRedirection() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let wrote = await session.run("echo hello > in.txt")
        #expect(wrote.exitCode == 0)
        let result = await session.run("cat < in.txt")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "hello\n")
    }

    @Test("globbing expansion")
    func globbingExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let touched = await session.run("touch a.txt b.txt c.md")
        #expect(touched.exitCode == 0)

        let result = await session.run("echo *.txt")
        #expect(result.exitCode == 0)

        let words = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        #expect(words.count == 2)
        #expect(words.contains("/home/user/a.txt"))
        #expect(words.contains("/home/user/b.txt"))
    }

    @Test("history formatting")
    func historyCommandFormatsEntries() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("echo one")
        _ = await session.run("echo two")
        let history = await session.run("history")

        #expect(history.exitCode == 0)
        #expect(history.stdoutString.contains("1  echo one"))
        #expect(history.stdoutString.contains("2  echo two"))
        #expect(history.stdoutString.contains("3  history"))
    }
}
