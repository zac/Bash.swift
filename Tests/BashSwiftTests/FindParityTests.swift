import Foundation
import Testing
@testable import BashSwift

@Suite("Find Parity")
struct FindParityTests {
    @Test("boolean operators and parentheses")
    func booleanOperatorsAndParentheses() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p project/src")
        _ = await session.run("printf '# readme\\n' > project/README.md")
        _ = await session.run("printf '{}\\n' > project/package.json")
        _ = await session.run("printf 'swift\\n' > project/src/main.swift")

        let result = await session.run("find project \\( -name \"*.md\" -o -name \"*.json\" \\)")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "/home/user/project/README.md\n/home/user/project/package.json\n")
    }

    @Test("negation with type filtering")
    func negationWithTypeFiltering() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p corpus")
        _ = await session.run("printf 'a\\n' > corpus/a.txt")
        _ = await session.run("printf 'b\\n' > corpus/b.md")

        let result = await session.run("find corpus -type f ! -name \"*.txt\"")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "/home/user/corpus/b.md\n")
    }

    @Test("exec single-file mode")
    func execSingleFileMode() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p docs")
        _ = await session.run("printf 'A\\n' > docs/a.txt")
        _ = await session.run("printf 'B\\n' > docs/b.txt")

        let result = await session.run("find docs -name \"*.txt\" -exec cat {} \\;")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "A\nB\n")
    }

    @Test("exec batch mode")
    func execBatchMode() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p docs")
        _ = await session.run("touch docs/a.txt docs/b.txt")

        let result = await session.run("find docs -name \"*.txt\" -exec echo {} +")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "/home/user/docs/a.txt /home/user/docs/b.txt\n")
    }

    @Test("print0 emits null-delimited paths")
    func print0EmitsNullDelimitedPaths() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p docs")
        _ = await session.run("touch docs/a.txt docs/b.txt")

        let result = await session.run("find docs -type f -print0")
        #expect(result.exitCode == 0)
        #expect(
            result.stdout == Data("/home/user/docs/a.txt\0/home/user/docs/b.txt\0".utf8)
        )
    }

    @Test("prune with OR expression")
    func pruneWithOrExpression() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p project/node_modules project/src")
        _ = await session.run("printf 'ignored\\n' > project/node_modules/pkg.ts")
        _ = await session.run("printf 'kept\\n' > project/src/main.ts")

        let result = await session.run("find project -name node_modules -prune -o -name \"*.ts\" -print")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "/home/user/project/src/main.ts\n")
    }

    @Test("maxdepth limits recursion")
    func maxDepthLimitsRecursion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p nested/sub")
        _ = await session.run("printf 'top\\n' > nested/top.txt")
        _ = await session.run("printf 'deep\\n' > nested/sub/deep.txt")

        let result = await session.run("find nested -maxdepth 1 -type f -exec cat {} \\;")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "top\n")
    }

    @Test("unknown predicate fails")
    func unknownPredicateFails() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("find . --definitely-invalid-flag")
        #expect(result.exitCode != 0)
        #expect(result.stderrString.contains("unknown predicate"))
    }
}
