import ArgumentParser
import Foundation

struct ClearCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "clear"
    static let overview = "Clear the terminal screen"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        context.writeStdout("\u{001B}[2J\u{001B}[H")
        return 0
    }
}

struct DateCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Use UTC")
        var u = false
    }

    static let name = "date"
    static let overview = "Display current date and time"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = options.u ? TimeZone(secondsFromGMT: 0) : .current
        context.writeStdout("\(formatter.string(from: Date()))\n")
        return 0
    }
}

struct HostnameCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "hostname"
    static let overview = "Show or set system host name"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = options
        let host = ProcessInfo.processInfo.hostName
        if host.isEmpty {
            context.writeStdout("localhost\n")
        } else {
            context.writeStdout("\(host)\n")
        }
        return 0
    }
}

struct FalseCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "false"
    static let overview = "Return unsuccessful status"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        return 1
    }
}

struct WhoamiCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "whoami"
    static let overview = "Print effective user name"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = options
        let user = context.environment["USER"] ?? NSUserName()
        context.writeStdout((user.isEmpty ? "user" : user) + "\n")
        return 0
    }
}

struct HelpCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "help"
    static let overview = "Display information about builtin commands"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = options
        let commands = Set(context.availableCommands).sorted()
        for command in commands {
            context.writeStdout("\(command)\n")
        }
        return 0
    }
}

struct HistoryCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Show only the last N entries")
        var n: Int?
    }

    static let name = "history"
    static let overview = "Display command history"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let entries: ArraySlice<String>
        if let count = options.n, count >= 0 {
            entries = context.history.suffix(count)
        } else {
            entries = context.history[...]
        }

        var index = context.history.count - entries.count + 1
        for line in entries {
            context.writeStdout("\(index)  \(line)\n")
            index += 1
        }
        return 0
    }
}

struct SeqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Stop or start/stop/step values")
        var values: [String] = []
    }

    static let name = "seq"
    static let overview = "Print a sequence of numbers"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let numbers = options.values.compactMap(Double.init)
        let start: Double
        let step: Double
        let end: Double

        switch numbers.count {
        case 1:
            start = 1
            step = 1
            end = numbers[0]
        case 2:
            start = numbers[0]
            step = 1
            end = numbers[1]
        case 3:
            start = numbers[0]
            step = numbers[1]
            end = numbers[2]
        default:
            context.writeStderr("seq: expected 1, 2, or 3 numeric arguments\n")
            return 1
        }

        if step == 0 {
            context.writeStderr("seq: step cannot be 0\n")
            return 1
        }

        var current = start
        if step > 0 {
            while current <= end {
                context.writeStdout(Self.formatNumber(current) + "\n")
                current += step
            }
        } else {
            while current >= end {
                context.writeStdout(Self.formatNumber(current) + "\n")
                current += step
            }
        }

        return 0
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

struct SleepCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Number of seconds to sleep")
        var seconds: Double
    }

    static let name = "sleep"
    static let overview = "Delay for a specified amount of time"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        let nanos = UInt64(max(0, options.seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        return 0
    }
}

struct TimeCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "Command to execute")
        var command: [String] = []
    }

    static let name = "time"
    static let overview = "Run command and summarize execution time"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.command == ["--help"] || options.command == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Run command and summarize execution time
                
                USAGE: time <command> [<args> ...]
                
                """
            )
            return 0
        }

        guard !options.command.isEmpty else {
            context.writeStderr("time: missing command\n")
            return 1
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let result = await context.runSubcommand(options.command)
        let end = DispatchTime.now().uptimeNanoseconds

        context.stdout.append(result.stdout)
        context.stderr.append(result.stderr)

        let seconds = Double(end - start) / 1_000_000_000
        context.writeStderr(String(format: "real %.3fs\n", seconds))
        return result.exitCode
    }
}

struct TimeoutCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Timeout in seconds")
        var seconds: Double

        @Argument(parsing: .captureForPassthrough, help: "Command to execute")
        var command: [String] = []
    }

    static let name = "timeout"
    static let overview = "Run command with time limit"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.seconds >= 0 else {
            context.writeStderr("timeout: seconds must be >= 0\n")
            return 1
        }

        guard !options.command.isEmpty else {
            context.writeStderr("timeout: missing command\n")
            return 1
        }

        enum Outcome: Sendable {
            case completed(CommandResult, String, [String: String])
            case timedOut
        }

        let baseContext = context
        let timeoutNanos = UInt64(options.seconds * 1_000_000_000)
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let sub = await baseContext.runSubcommandIsolated(options.command, stdin: baseContext.stdin)
                return .completed(sub.result, sub.currentDirectory, sub.environment)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return .timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        switch outcome {
        case let .completed(result, newDirectory, newEnvironment):
            context.currentDirectory = newDirectory
            context.environment = newEnvironment
            context.stdout.append(result.stdout)
            context.stderr.append(result.stderr)
            return result.exitCode
        case .timedOut:
            context.writeStderr("timeout: command timed out\n")
            return 124
        }
    }
}

struct TrueCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "true"
    static let overview = "Return successful status"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        _ = options
        return 0
    }
}

struct WhichCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Command names")
        var names: [String] = []
    }

    static let name = "which"
    static let overview = "Locate a command"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.names.isEmpty else {
            context.writeStderr("which: missing command name\n")
            return 1
        }

        let available = Set(context.availableCommands)
        var failed = false

        for name in options.names {
            if available.contains(name) {
                context.writeStdout("/bin/\(name)\n")
            } else {
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}

