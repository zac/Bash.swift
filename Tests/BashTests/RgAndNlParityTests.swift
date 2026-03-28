import Foundation
import Testing
@testable import Bash

@Suite("Rg And Nl Parity")
struct RgAndNlParityTests {
    @Test("rg --files emits paths relative to current directory")
    func rgFilesUsesRelativePaths() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p Sources/App Tests/AppTests Docs")
        _ = await session.run("printf 'struct App {}\\n' > Sources/App/App.swift")
        _ = await session.run("printf 'struct Helpers {}\\n' > Sources/App/Helpers.swift")
        _ = await session.run("printf 'final class AppTests {}\\n' > Tests/AppTests/AppTests.swift")
        _ = await session.run("printf '# ignore\\n' > Docs/readme.md")

        let result = await session.run("rg --files | rg '^(Sources|Tests)/.*\\.swift$' | sort")
        #expect(result.exitCode == 0)
        #expect(
            result.stdoutString ==
                "Sources/App/App.swift\nSources/App/Helpers.swift\nTests/AppTests/AppTests.swift\n"
        )
    }

    @Test("rg --files preserves explicit relative roots")
    func rgFilesWithExplicitRoots() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p Sources/Core Tests/Core Docs")
        _ = await session.run("printf 'struct Core {}\\n' > Sources/Core/Core.swift")
        _ = await session.run("printf 'final class CoreTests {}\\n' > Tests/Core/CoreTests.swift")
        _ = await session.run("printf 'skip\\n' > Docs/info.txt")

        let result = await session.run("rg --files Sources Tests | sort")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "Sources/Core/Core.swift\nTests/Core/CoreTests.swift\n")
    }

    @Test("nl -ba numbers file lines for sed slicing")
    func nlBAForFileInput() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run(#"printf 'import Foundation\n\nlet title = "Bash"\nlet shell = true\nprint(title)\n' > App.swift"#)

        let result = await session.run("nl -ba App.swift | sed -n '3,5p'")
        #expect(result.exitCode == 0)
        #expect(
            result.stdoutString ==
                "     3\tlet title = \"Bash\"\n     4\tlet shell = true\n     5\tprint(title)\n"
        )
    }

    @Test("nl -ba supports stdin input")
    func nlBAForStandardInput() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("printf 'alpha\\n\\nbeta\\n' | nl -ba")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "     1\talpha\n     2\t\n     3\tbeta\n")
    }
}
