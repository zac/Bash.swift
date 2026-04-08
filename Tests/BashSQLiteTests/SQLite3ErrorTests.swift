import Foundation
import Testing
import Bash

#if SQLite

@Suite("SQLite3 Errors")
struct SQLite3ErrorTests {
    @Test("invalid option returns usage failure")
    func invalidOptionReturnsUsageFailure() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let result = await session.run("sqlite3 --definitely-invalid")
        #expect(result.exitCode == 2)
        #expect(result.stderrString.contains("unknown option"))
    }

    @Test("running without SQL input returns guidance instead of silent success")
    func noSQLInputReturnsGuidance() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let result = await session.run("sqlite3 app.db")
        #expect(result.exitCode == 2)
        #expect(result.stderrString.contains("interactive mode is not supported"))
    }

    @Test("readonly rejects write statements")
    func readonlyRejectsWriteStatements() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        _ = await session.run("sqlite3 app.db \"create table t(v); insert into t values('a');\"")

        let write = await session.run("sqlite3 -readonly app.db \"insert into t values('b');\"")
        #expect(write.exitCode == 1)
        #expect(write.stderrString.contains("readonly"))

        let read = await session.run("sqlite3 app.db \"select count(*) from t;\"")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "1\n")
    }

    @Test("bail controls whether script continues after SQL errors")
    func bailControlsContinuationAfterErrors() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let noBail = await session.run("sqlite3 :memory: \"select 1; this_is_bad_sql; select 2;\"")
        #expect(noBail.exitCode == 1)
        #expect(noBail.stdoutString == "1\n2\n")
        #expect(noBail.stderrString.contains("syntax error"))

        let withBail = await session.run("sqlite3 -bail :memory: \"select 1; this_is_bad_sql; select 2;\"")
        #expect(withBail.exitCode == 1)
        #expect(withBail.stdoutString == "1\n")
        #expect(withBail.stderrString.contains("syntax error"))
    }
}

#endif
