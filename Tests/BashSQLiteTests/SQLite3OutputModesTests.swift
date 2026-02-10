import Foundation
import Testing
import Bash
import BashSQLite

@Suite("SQLite3 Output Modes")
struct SQLite3OutputModesTests {
    private let seedSQL = "create table t(a,b); insert into t values (1,'x'); insert into t values (2,null);"
    private let querySQL = "select a,b from t order by a;"

    @Test("list csv and json modes")
    func listCsvAndJsonModes() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let list = await session.run("sqlite3 :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(list.exitCode == 0)
        #expect(list.stdoutString == "1|x\n2|\n")

        let csv = await session.run("sqlite3 -csv -header :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(csv.exitCode == 0)
        #expect(csv.stdoutString == "a,b\n1,x\n2,\n")

        let json = await session.run("sqlite3 -json :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(json.exitCode == 0)
        #expect(json.stdoutString == "[{\"a\":1,\"b\":\"x\"},{\"a\":2,\"b\":null}]\n")
    }

    @Test("line column table and markdown modes")
    func lineColumnTableAndMarkdownModes() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let line = await session.run("sqlite3 -line :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(line.exitCode == 0)
        #expect(line.stdoutString == "a = 1\nb = x\n\na = 2\nb = \n")

        let column = await session.run("sqlite3 -column -header :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(column.exitCode == 0)
        #expect(column.stdoutString.contains("a  b"))
        #expect(column.stdoutString.contains("1  x"))

        let table = await session.run("sqlite3 -table -header :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(table.exitCode == 0)
        #expect(table.stdoutString.contains("+"))
        #expect(table.stdoutString.contains("| a | b |"))

        let markdown = await session.run("sqlite3 -markdown :memory: \"\(seedSQL) \(querySQL)\"")
        #expect(markdown.exitCode == 0)
        #expect(markdown.stdoutString == "| a | b |\n| --- | --- |\n| 1 | x |\n| 2 |  |\n")
    }

    @Test("separator newline and nullvalue options")
    func separatorNewlineAndNullValueOptions() async throws {
        let (session, root) = try await SQLiteTestSupport.makeReadWriteSession()
        defer { SQLiteTestSupport.removeDirectory(root) }

        let result = await session.run(
            "sqlite3 -list -separator , -nullvalue NULL -newline '\\n--\\n' :memory: \"\(seedSQL) \(querySQL)\""
        )

        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "1,x\n--\n2,NULL\n--\n")
    }
}
