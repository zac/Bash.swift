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

    @Test("regex and iregex matching")
    func regexAndIregexMatching() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p regex")
        _ = await session.run("printf 'a\\n' > regex/one.txt")
        _ = await session.run("printf 'b\\n' > regex/TWO.TXT")
        _ = await session.run("printf 'c\\n' > regex/note.md")

        let regex = await session.run("find regex -regex '.*\\.md$'")
        #expect(regex.exitCode == 0)
        #expect(regex.stdoutString == "/home/user/regex/note.md\n")

        let iregex = await session.run("find regex -iregex '.*\\.txt$'")
        #expect(iregex.exitCode == 0)
        #expect(iregex.stdoutString == "/home/user/regex/TWO.TXT\n/home/user/regex/one.txt\n")
    }

    @Test("size mtime and perm predicates")
    func sizeMtimeAndPermPredicates() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p meta")
        _ = await session.run("printf 'abc\\n' > meta/small.txt")
        _ = await session.run("printf '1234567890\\n' > meta/big.txt")
        _ = await session.run("touch meta/old.txt")
        _ = await session.run("chmod 600 meta/old.txt")

        let oldPhysicalPath = root
            .appendingPathComponent("home/user/meta", isDirectory: true)
            .appendingPathComponent("old.txt")
            .path
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(3 * 24 * 60 * 60))],
            ofItemAtPath: oldPhysicalPath
        )

        let size = await session.run("find meta -type f -size +5c")
        #expect(size.exitCode == 0)
        #expect(size.stdoutString == "/home/user/meta/big.txt\n")

        let mtime = await session.run("find meta -type f -mtime +1")
        #expect(mtime.exitCode == 0)
        #expect(mtime.stdoutString == "/home/user/meta/old.txt\n")

        let perm = await session.run("find meta -type f -perm 600")
        #expect(perm.exitCode == 0)
        #expect(perm.stdoutString == "/home/user/meta/old.txt\n")
    }

    @Test("printf action")
    func printfAction() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p fmt/nested")
        _ = await session.run("printf 'hello\\n' > fmt/nested/a.txt")

        let result = await session.run("find fmt -name '*.txt' -printf '%P:%f:%s:%d\\n'")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "nested/a.txt:a.txt:6:2\n")
    }

    @Test("delete action for files and directories")
    func deleteActionForFilesAndDirectories() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p trash/empty")
        _ = await session.run("printf 'temp\\n' > trash/remove.tmp")
        _ = await session.run("printf 'keep\\n' > trash/keep.txt")

        let deleteFile = await session.run("find trash -name '*.tmp' -delete")
        #expect(deleteFile.exitCode == 0)

        let afterFileDelete = await session.run("ls trash")
        #expect(afterFileDelete.exitCode == 0)
        #expect(afterFileDelete.stdoutString == "empty keep.txt\n")

        let deleteEmptyDir = await session.run("find trash -type d -name empty -delete")
        #expect(deleteEmptyDir.exitCode == 0)

        let afterDirDelete = await session.run("ls trash")
        #expect(afterDirDelete.exitCode == 0)
        #expect(afterDirDelete.stdoutString == "keep.txt\n")
    }

    @Test("delete action fails for non-empty directory")
    func deleteActionFailsForNonEmptyDirectory() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p busy/sub")
        _ = await session.run("printf 'x\\n' > busy/sub/file.txt")

        let delete = await session.run("find busy -type d -name sub -delete")
        #expect(delete.exitCode != 0)
        #expect(delete.stderrString.contains("cannot delete"))

        let stillThere = await session.run("ls busy")
        #expect(stillThere.exitCode == 0)
        #expect(stillThere.stdoutString == "sub\n")
    }
}
