import Foundation
import Testing
@testable import Bash

@Suite("Parser and Filesystem")
struct ParserAndFilesystemTests {
    @Test("lexer handles quotes and escapes")
    func lexerHandlesQuotesAndEscapes() throws {
        let tokens = try ShellLexer.tokenize("echo \"a b\" 'c d' e\\ f")
        #expect(tokens.count == 4)

        switch tokens[0] {
        case let .word(cmd):
            #expect(cmd.rawValue == "echo")
        default:
            Issue.record("expected word token")
        }

        switch tokens[1] {
        case let .word(second):
            #expect(second.rawValue == "a b")
        default:
            Issue.record("expected second word token")
        }

        switch tokens[2] {
        case let .word(third):
            #expect(third.rawValue == "c d")
        default:
            Issue.record("expected third word token")
        }

        switch tokens[3] {
        case let .word(fourth):
            #expect(fourth.rawValue == "e f")
        default:
            Issue.record("expected fourth word token")
        }
    }

    @Test("parser builds pipeline and chain segments")
    func parserBuildsPipelineAndChainSegments() throws {
        let parsed = try ShellParser.parse("echo hi | grep h && echo ok; echo done")
        #expect(parsed.segments.count == 3)
        #expect(parsed.segments[0].pipeline.count == 2)
        #expect(parsed.segments[1].connector == .and)
        #expect(parsed.segments[2].connector == .sequence)
    }

    @Test("parser treats newlines as sequence separators")
    func parserTreatsNewlinesAsSequenceSeparators() throws {
        let parsed = try ShellParser.parse("echo one\necho two")
        #expect(parsed.segments.count == 2)
        #expect(parsed.segments[0].connector == nil)
        #expect(parsed.segments[1].connector == .sequence)
    }

    @Test("parser ignores shell comments")
    func parserIgnoresShellComments() throws {
        let parsed = try ShellParser.parse("echo one # comment\necho two")
        #expect(parsed.segments.count == 2)
        #expect(parsed.segments[0].connector == nil)
        #expect(parsed.segments[1].connector == .sequence)
    }

    @Test("parser rejects trailing chain operator")
    func parserRejectsTrailingChainOperator() {
        do {
            _ = try ShellParser.parse("echo hi &&")
            Issue.record("expected parser error")
        } catch {
            // expected
        }
    }

    @Test("parser allows trailing semicolon")
    func parserAllowsTrailingSemicolon() throws {
        let parsed = try ShellParser.parse("echo hi;")
        #expect(parsed.segments.count == 1)
        #expect(parsed.segments[0].connector == nil)
        #expect(parsed.segments[0].pipeline.count == 1)
    }

    @Test("parser supports background segments")
    func parserSupportsBackgroundSegments() throws {
        let parsed = try ShellParser.parse("sleep 1 & echo done")
        #expect(parsed.segments.count == 2)
        #expect(parsed.segments[0].runInBackground == true)
        #expect(parsed.segments[1].connector == .sequence)
    }

    @Test("parser allows trailing background operator")
    func parserAllowsTrailingBackgroundOperator() throws {
        let parsed = try ShellParser.parse("sleep 1 &")
        #expect(parsed.segments.count == 1)
        #expect(parsed.segments[0].runInBackground == true)
    }

    @Test("parser captures here document bodies")
    func parserCapturesHereDocumentBodies() throws {
        let parsed = try ShellParser.parse(
            """
            cat <<'EOF'
            hello
            EOF
            echo done
            """
        )

        #expect(parsed.segments.count == 2)
        #expect(parsed.segments[0].pipeline.count == 1)

        let command = parsed.segments[0].pipeline[0]
        #expect(command.words.map(\.rawValue) == ["cat"])
        #expect(command.redirections.count == 1)
        #expect(command.redirections[0].type == .stdin)
        if command.redirections[0].target != nil {
            Issue.record("expected here document redirection without file target")
        }
        #expect(command.redirections[0].hereDocument?.delimiter == "EOF")
        #expect(command.redirections[0].hereDocument?.body == "hello\n")
        #expect(command.redirections[0].hereDocument?.stripsLeadingTabs == false)
        #expect(parsed.segments[1].connector == .sequence)
    }

    @Test("parser captures tab-stripped here document bodies")
    func parserCapturesTabStrippedHereDocumentBodies() throws {
        let parsed = try ShellParser.parse(
            """
            cat <<-'EOF'
             \tkeep-leading-space
            \ttrim-leading-tab
            \tEOF
            """
        )

        let command = parsed.segments[0].pipeline[0]
        let hereDocument = command.redirections[0].hereDocument
        #expect(hereDocument?.delimiter == "EOF")
        #expect(hereDocument?.stripsLeadingTabs == true)
        #expect(
            hereDocument?.body ==
                """
                 \tkeep-leading-space
                trim-leading-tab
                """
                + "\n"
        )
    }

    @Test("default unix-like layout is created")
    func defaultUnixLikeLayoutIsCreated() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let rootList = await session.run("ls /")
        #expect(rootList.exitCode == 0)

        let output = rootList.stdoutString
        #expect(output.contains("home"))
        #expect(output.contains("bin"))
        #expect(output.contains("usr"))
        #expect(output.contains("tmp"))
    }

    @Test("path jail blocks symlink escape outside root")
    func pathJailBlocksSymlinkEscapeOutsideRoot() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let outside = try TestSupport.makeTempDirectory(prefix: "BashOutside")
        defer { TestSupport.removeDirectory(outside) }

        let outsideFile = outside.appendingPathComponent("outside.txt")
        try Data("top secret".utf8).write(to: outsideFile)

        let link = await session.run("ln -s \(outsideFile.path) leak")
        #expect(link.exitCode == 0)

        let read = await session.run("cat leak")
        #expect(read.exitCode != 0)
        #expect(read.stderrString.contains("invalid path"))
    }

    @Test("filesystems reject paths with null bytes")
    func filesystemsRejectPathsWithNullBytes() async throws {
        let inMemory = InMemoryFilesystem()
        try inMemory.configureForSession()

        do {
            _ = try await inMemory.readFile(path: "/bad\u{0}name")
            Issue.record("expected in-memory null-byte rejection")
        } catch {
            #expect("\(error)".contains("null byte"))
        }

        let root = try TestSupport.makeTempDirectory(prefix: "BashNullPath")
        defer { TestSupport.removeDirectory(root) }

        let readWrite = try ReadWriteFilesystem(rootDirectory: root)
        do {
            try await readWrite.writeFile(path: "/bad\u{0}name", data: Data(), append: false)
            Issue.record("expected read-write null-byte rejection")
        } catch {
            #expect("\(error)".contains("null byte"))
        }
    }

    @Test("command stubs created for path invocation")
    func commandStubsCreatedForPathInvocation() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let which = await session.run("which ls")
        #expect(which.exitCode == 0)
        #expect(which.stdoutString == "/bin/ls\n")

        let byPath = await session.run("/bin/ls")
        #expect(byPath.exitCode == 0)
    }

    @Test("in-memory filesystem keeps writes off disk")
    func inMemoryFilesystemKeepsWritesOffDisk() async throws {
        let root = try TestSupport.makeTempDirectory(prefix: "BashInMemory")
        defer { TestSupport.removeDirectory(root) }

        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(
                filesystem: InMemoryFilesystem(),
                layout: .unixLike,
                initialEnvironment: [:],
                enableGlobbing: true,
                maxHistory: 1_000
            )
        )

        let touch = await session.run("touch mem.txt")
        #expect(touch.exitCode == 0)

        let ls = await session.run("ls")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains("mem.txt"))

        let physicalPath = root
            .appendingPathComponent("home/user", isDirectory: true)
            .appendingPathComponent("mem.txt")
            .path
        #expect(FileManager.default.fileExists(atPath: physicalPath) == false)
    }
}
