import Foundation
import Testing
@testable import BashSwift

@Suite("Session Integration")
struct SessionIntegrationTests {
    @Test("touch then ls mutates read-write filesystem")
    func touchThenLsShowsFileAndMutatesReadWriteFilesystem() async throws {
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

    @Test("printf base64 and digest commands")
    func printfBase64AndDigestCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let printf = await session.run("printf 'hello %s %d\\n' world 7")
        #expect(printf.exitCode == 0)
        #expect(printf.stdoutString == "hello world 7\n")

        let encoded = await session.run("printf hello | base64")
        #expect(encoded.exitCode == 0)
        #expect(encoded.stdoutString == "aGVsbG8=\n")

        let decoded = await session.run("printf aGVsbG8= | base64 -d")
        #expect(decoded.exitCode == 0)
        #expect(decoded.stdoutString == "hello")

        let sha256 = await session.run("printf hello | sha256sum")
        #expect(sha256.exitCode == 0)
        #expect(sha256.stdoutString == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  -\n")

        let sha1 = await session.run("printf hello | sha1sum")
        #expect(sha1.exitCode == 0)
        #expect(sha1.stdoutString == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d  -\n")

        let md5 = await session.run("printf hello | md5sum")
        #expect(md5.exitCode == 0)
        #expect(md5.stdoutString == "5d41402abc4b2a76b9719d911017c592  -\n")
    }

    @Test("chmod file and tree commands")
    func chmodFileAndTreeCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p docs/nested")
        _ = await session.run("echo hi > docs/nested/note.txt")

        let chmod = await session.run("chmod 600 docs/nested/note.txt")
        #expect(chmod.exitCode == 0)

        let stat = await session.run("stat docs/nested/note.txt")
        #expect(stat.exitCode == 0)
        #expect(stat.stdoutString.contains("Mode: 600"))

        let file = await session.run("file docs/nested/note.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString.contains("ASCII text"))

        let tree = await session.run("tree docs")
        #expect(tree.exitCode == 0)
        #expect(tree.stdoutString.contains("docs\n"))
        #expect(tree.stdoutString.contains("  nested\n"))
        #expect(tree.stdoutString.contains("    note.txt\n"))
    }

    @Test("hostname and whoami commands")
    func hostnameAndWhoamiCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let hostname = await session.run("hostname")
        #expect(hostname.exitCode == 0)
        #expect(!hostname.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let whoami = await session.run("whoami")
        #expect(whoami.exitCode == 0)
        #expect(whoami.stdoutString == "user\n")
    }

    @Test("time and timeout commands")
    func timeAndTimeoutCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let timed = await session.run("time echo hi")
        #expect(timed.exitCode == 0)
        #expect(timed.stdoutString == "hi\n")
        #expect(timed.stderrString.contains("real "))

        let timeout = await session.run("timeout 0.01 sleep 0.2")
        #expect(timeout.exitCode == 124)
        #expect(timeout.stderrString.contains("timed out"))
    }
}
