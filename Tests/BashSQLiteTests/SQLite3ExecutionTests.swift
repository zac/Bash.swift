import Foundation
import Testing
import Bash

#if SQLite

@Suite("SQLite3 Execution")
struct SQLite3ExecutionTests {
    @Test("inline SQL and stdin SQL")
    func inlineAndStdinSQL() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let inline = await session.run("sqlite3 :memory: \"select 'ok';\"")
        #expect(inline.exitCode == 0)
        #expect(inline.stdoutString == "ok\n")

        let stdinScript = "create table t(v); insert into t values('a'); insert into t values('b'); select v from t order by v;"
        let stdinResult = await session.run("sqlite3 :memory:", stdin: Data(stdinScript.utf8))
        #expect(stdinResult.exitCode == 0)
        #expect(stdinResult.stdoutString == "a\nb\n")
    }

    @Test("file backed persistence across runs")
    func fileBackedPersistenceAcrossRuns() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let create = await session.run("sqlite3 app.db \"create table items(v); insert into items values('one');\"")
        #expect(create.exitCode == 0)

        let read = await session.run("sqlite3 app.db \"select v from items;\"")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "one\n")

        let physical = root
            .appendingPathComponent("home/user", isDirectory: true)
            .appendingPathComponent("app.db")
            .path
        #expect(FileManager.default.fileExists(atPath: physical))
    }

    @Test("memory databases do not persist between runs")
    func memoryDatabasesDoNotPersistBetweenRuns() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let create = await session.run("sqlite3 :memory: \"create table t(v); insert into t values(1);\"")
        #expect(create.exitCode == 0)

        let query = await session.run("sqlite3 :memory: \"select v from t;\"")
        #expect(query.exitCode != 0)
        #expect(query.stderrString.contains("no such table"))
    }

    @Test("unquoted SQL tokens after database are treated as SQL")
    func unquotedSQLTokensAfterDatabase() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let create = await session.run("sqlite3 app.db create table items(v integer)")
        #expect(create.exitCode == 0)

        let insert = await session.run("sqlite3 app.db insert into items values (7)")
        #expect(insert.exitCode == 0)

        let query = await session.run("sqlite3 app.db select v from items")
        #expect(query.exitCode == 0)
        #expect(query.stdoutString == "7\n")
    }

    @Test("shell accepts trailing semicolon after sqlite command")
    func shellAcceptsTrailingSemicolonAfterSQLiteCommand() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let create = await session.run("sqlite3 users.db \"create table users(id integer primary key, name text)\";")
        #expect(create.exitCode == 0)

        let insert = await session.run("sqlite3 users.db \"insert into users(name) values ('Alice')\";")
        #expect(insert.exitCode == 0)

        let query = await session.run("sqlite3 users.db \"select name from users\";")
        #expect(query.exitCode == 0)
        #expect(query.stdoutString == "Alice\n")
    }
}

#endif
