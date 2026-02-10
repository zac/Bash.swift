import Foundation
import Testing
import Bash
import BashSQLite

@Suite("SQLite3 Filesystem")
struct SQLite3FilesystemTests {
    @Test("in-memory filesystem stores sqlite database bytes")
    func inMemoryFilesystemStoresDatabaseBytes() async throws {
        let session = try await SQLiteTestSupport.makeInMemorySession()

        let create = await session.run("sqlite3 local.db \"create table t(v); insert into t values(9);\"")
        #expect(create.exitCode == 0)

        let read = await session.run("sqlite3 local.db \"select v from t;\"")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "9\n")

        let ls = await session.run("ls")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains("local.db"))
    }

    @Test("readonly mode on missing database fails deterministically")
    func readonlyOnMissingDatabaseFails() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let result = await session.run("sqlite3 -readonly missing.db \"select 1;\"")
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("unable to open database file"))
    }

    @Test("sqlite3 command can be registered on existing session")
    func sqliteCommandCanBeRegisteredOnExistingSession() async throws {
        let root = try SQLiteTestSupport.makeTempDirectory()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let session = try await BashSession(rootDirectory: root)
        let missing = await session.run("sqlite3 --help")
        #expect(missing.exitCode == 127)

        await session.registerSQLite3()
        let available = await session.run("sqlite3 --help")
        #expect(available.exitCode == 0)
        #expect(available.stdoutString.contains("USAGE:"))
    }
}
