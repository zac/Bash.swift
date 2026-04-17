import Foundation
import SQLite3
import BashCore

enum SQLiteCell: Sendable {
    case null
    case integer(Int64)
    case float(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteResultSet: Sendable {
    var columns: [String]
    var rows: [[SQLiteCell]]
}

struct SQLiteExecutionOutcome: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

enum SQLiteEngine {
    static func execute(
        invocation: SQLiteInvocation,
        mainScript: String?,
        context: inout CommandContext
    ) async -> SQLiteExecutionOutcome {
        var scripts = invocation.commandScripts
        if let mainScript {
            let trimmed = mainScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                scripts.append(mainScript)
            }
        }

        if scripts.isEmpty {
            return SQLiteExecutionOutcome(stdout: "", stderr: "", exitCode: 0)
        }

        if invocation.database == ":memory:" {
            return executeAtPath(
                databasePath: ":memory:",
                invocation: invocation,
                scripts: scripts
            )
        }

        let virtualPath = context.resolvePath(invocation.database)
        let exists = await context.filesystem.exists(path: virtualPath)

        if invocation.readOnly, !exists {
            return SQLiteExecutionOutcome(
                stdout: "",
                stderr: "sqlite3: unable to open database file\n",
                exitCode: 1
            )
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bashswift-sqlite-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        if exists {
            do {
                let existing = try await context.filesystem.readFile(path: virtualPath)
                try existing.write(to: tempURL, options: .atomic)
            } catch {
                return SQLiteExecutionOutcome(
                    stdout: "",
                    stderr: "sqlite3: \(error)\n",
                    exitCode: 1
                )
            }
        }

        let runOutcome = executeAtPath(
            databasePath: tempURL.path,
            invocation: invocation,
            scripts: scripts
        )

        if !invocation.readOnly {
            do {
                let persisted = try Data(contentsOf: tempURL)
                try await context.filesystem.writeFile(path: virtualPath, data: persisted, append: false)
            } catch {
                var stderr = runOutcome.stderr
                stderr += "sqlite3: failed to persist database: \(error)\n"
                return SQLiteExecutionOutcome(
                    stdout: runOutcome.stdout,
                    stderr: stderr,
                    exitCode: 1
                )
            }
        }

        return runOutcome
    }

    private static func executeAtPath(
        databasePath: String,
        invocation: SQLiteInvocation,
        scripts: [String]
    ) -> SQLiteExecutionOutcome {
        let openFlags: Int32
        if invocation.readOnly {
            openFlags = Int32(SQLITE_OPEN_READONLY)
        } else {
            openFlags = Int32(SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databasePath, &database, openFlags, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = sqliteErrorMessage(database)
            sqlite3_close(database)
            return SQLiteExecutionOutcome(
                stdout: "",
                stderr: "sqlite3: \(message)\n",
                exitCode: 1
            )
        }

        defer {
            sqlite3_close(database)
        }

        var resultSets: [SQLiteResultSet] = []
        var errors: [String] = []
        var shouldStop = false

        for script in scripts {
            let execution = executeScript(script, database: database, bail: invocation.bail)
            resultSets.append(contentsOf: execution.resultSets)
            errors.append(contentsOf: execution.errors)
            if execution.shouldStop {
                shouldStop = true
                break
            }
        }

        let stdout = SQLiteFormatters.render(resultSets: resultSets, invocation: invocation)
        let stderr = errors.map { "sqlite3: \($0)\n" }.joined()
        if shouldStop || !errors.isEmpty {
            return SQLiteExecutionOutcome(stdout: stdout, stderr: stderr, exitCode: 1)
        }

        return SQLiteExecutionOutcome(stdout: stdout, stderr: stderr, exitCode: 0)
    }

    private static func executeScript(
        _ script: String,
        database: OpaquePointer,
        bail: Bool
    ) -> (resultSets: [SQLiteResultSet], errors: [String], shouldStop: Bool) {
        var resultSets: [SQLiteResultSet] = []
        var errors: [String] = []
        var shouldStop = false

        script.withCString { basePointer in
            var currentPointer: UnsafePointer<CChar>? = basePointer

            while let pointer = currentPointer, pointer.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?

                let prepareResult = sqlite3_prepare_v2(database, pointer, -1, &statement, &tail)
                if prepareResult != SQLITE_OK {
                    errors.append(sqliteErrorMessage(database))
                    if bail {
                        shouldStop = true
                        break
                    }

                    guard let tail, tail != pointer else {
                        break
                    }
                    currentPointer = tail
                    continue
                }

                currentPointer = tail

                guard let statement else {
                    if let tail, tail != pointer {
                        continue
                    }
                    break
                }

                defer {
                    sqlite3_finalize(statement)
                }

                let columnCount = Int(sqlite3_column_count(statement))
                var columns: [String] = []
                if columnCount > 0 {
                    columns.reserveCapacity(columnCount)
                    for index in 0..<columnCount {
                        let name = sqlite3_column_name(statement, Int32(index)).flatMap { String(cString: $0) } ?? "column\(index + 1)"
                        columns.append(name)
                    }
                }

                var rows: [[SQLiteCell]] = []
                var stepFailed = false

                while true {
                    let stepResult = sqlite3_step(statement)
                    if stepResult == SQLITE_ROW {
                        var row: [SQLiteCell] = []
                        row.reserveCapacity(columnCount)
                        for index in 0..<columnCount {
                            row.append(readCell(statement: statement, columnIndex: Int32(index)))
                        }
                        rows.append(row)
                    } else if stepResult == SQLITE_DONE {
                        break
                    } else {
                        errors.append(sqliteErrorMessage(database))
                        stepFailed = true
                        break
                    }
                }

                if columnCount > 0 {
                    resultSets.append(SQLiteResultSet(columns: columns, rows: rows))
                }

                if stepFailed, bail {
                    shouldStop = true
                    break
                }

                if currentPointer == nil {
                    break
                }
            }
        }

        return (resultSets, errors, shouldStop)
    }

    private static func readCell(statement: OpaquePointer, columnIndex: Int32) -> SQLiteCell {
        let type = sqlite3_column_type(statement, columnIndex)

        switch type {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, columnIndex))
        case SQLITE_FLOAT:
            return .float(sqlite3_column_double(statement, columnIndex))
        case SQLITE_TEXT:
            guard let rawText = sqlite3_column_text(statement, columnIndex) else {
                return .text("")
            }
            let length = Int(sqlite3_column_bytes(statement, columnIndex))
            let data = Data(bytes: rawText, count: length)
            return .text(String(decoding: data, as: UTF8.self))
        case SQLITE_BLOB:
            guard let rawBlob = sqlite3_column_blob(statement, columnIndex) else {
                return .blob(Data())
            }
            let length = Int(sqlite3_column_bytes(statement, columnIndex))
            return .blob(Data(bytes: rawBlob, count: length))
        default:
            return .null
        }
    }

    private static func sqliteErrorMessage(_ database: OpaquePointer?) -> String {
        guard let database else {
            return "unknown sqlite error"
        }

        if let messagePointer = sqlite3_errmsg(database) {
            return String(cString: messagePointer)
        }

        return "unknown sqlite error"
    }
}
