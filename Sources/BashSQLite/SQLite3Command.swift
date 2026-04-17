import ArgumentParser
import Foundation
import SQLite3
import BashCore

public struct SQLite3Command: BuiltinCommand {
    public struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "sqlite3 arguments")
        public var arguments: [String] = []

        public init() {}
    }

    public static let name = "sqlite3"
    public static let overview = "Execute SQL statements against a SQLite database"

    public static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.arguments.contains("--help") || options.arguments.contains("-h") {
            context.writeStdout(SQLiteArgumentModel.helpText)
            return 0
        }

        let invocation: SQLiteInvocation
        switch SQLiteArgumentModel.parse(options.arguments) {
        case let .success(parsed):
            invocation = parsed
        case let .usageError(message):
            context.writeStderr(message)
            return 2
        }

        if invocation.showVersion {
            context.writeStdout(String(cString: sqlite3_libversion()) + "\n")
            return 0
        }

        let mainScript: String?
        if let sql = invocation.sql {
            mainScript = sql
        } else {
            let stdin = String(decoding: context.stdin, as: UTF8.self)
            mainScript = stdin.isEmpty ? nil : stdin
        }

        if invocation.commandScripts.isEmpty, mainScript == nil {
            context.writeStderr(
                "sqlite3: interactive mode is not supported; pass SQL as arguments or via stdin\n"
            )
            return 2
        }

        let outcome = await SQLiteEngine.execute(
            invocation: invocation,
            mainScript: mainScript,
            context: &context
        )

        if !outcome.stdout.isEmpty {
            context.writeStdout(outcome.stdout)
        }
        if !outcome.stderr.isEmpty {
            context.writeStderr(outcome.stderr)
        }

        return outcome.exitCode
    }
}
