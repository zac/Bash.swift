import Foundation
import Testing
import Bash

#if SQLite

@Suite("SQLite3 Options")
struct SQLite3OptionsTests {
    @Test("help and version")
    func helpAndVersion() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let help = await session.run("sqlite3 --help")
        #expect(help.exitCode == 0)
        #expect(help.stdoutString.contains("USAGE:"))

        let shortHelp = await session.run("sqlite3 -h")
        #expect(shortHelp.exitCode == 0)
        #expect(shortHelp.stdoutString.contains("USAGE:"))

        let version = await session.run("sqlite3 -version")
        #expect(version.exitCode == 0)
        #expect(!version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("header and noheader precedence")
    func headerAndNoHeaderPrecedence() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let noHeader = await session.run("sqlite3 -header -noheader :memory: \"select 1 as value;\"")
        #expect(noHeader.exitCode == 0)
        #expect(noHeader.stdoutString == "1\n")

        let header = await session.run("sqlite3 -noheader -header :memory: \"select 1 as value;\"")
        #expect(header.exitCode == 0)
        #expect(header.stdoutString == "value\n1\n")
    }

    @Test("cmd executes before main SQL")
    func cmdExecutesBeforeMainSQL() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let result = await session.run(
            "sqlite3 -cmd \"create table t(x);\" -cmd \"insert into t values (7);\" :memory: \"select x from t;\""
        )

        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "7\n")
    }

    @Test("double dash stops option parsing")
    func doubleDashStopsOptionParsing() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let result = await session.run("sqlite3 -- :memory: \"select 5;\"")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "5\n")
    }
}

#endif
