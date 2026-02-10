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
    struct Options: ParsableArguments {
        @Argument(help: "Optional command name")
        var command: String?
    }

    static let name = "help"
    static let overview = "Display information about builtin commands"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if let command = options.command {
            let helpResult = await context.runSubcommandIsolated([command, "--help"], stdin: Data())
            context.stdout.append(helpResult.result.stdout)
            context.stderr.append(helpResult.result.stderr)
            return helpResult.result.exitCode
        }

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
        @Option(name: .short, help: "Use separator string")
        var s: String?

        @Flag(name: .short, help: "Equalize width with leading zeroes")
        var w = false

        @Argument(help: "Stop or start/stop/step values")
        var values: [String] = []
    }

    static let name = "seq"
    static let overview = "Print a sequence of numbers"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.values.isEmpty else {
            context.writeStderr("seq: missing operand\n")
            return 1
        }

        if let invalid = options.values.first(where: { Double($0) == nil }) {
            context.writeStderr("seq: invalid floating point argument: '\(invalid)'\n")
            return 1
        }

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

        let precision = options.values.map(decimalPrecision).max() ?? 0
        let separator = options.s ?? "\n"
        var rendered: [String] = []
        var current = start
        let epsilon = 1e-10
        var iterations = 0
        let maxIterations = 100_000
        if step > 0 {
            while current <= end + epsilon {
                guard iterations < maxIterations else { break }
                rendered.append(Self.formatNumber(current, precision: precision))
                current += step
                iterations += 1
            }
        } else {
            while current >= end - epsilon {
                guard iterations < maxIterations else { break }
                rendered.append(Self.formatNumber(current, precision: precision))
                current += step
                iterations += 1
            }
        }

        if options.w, !rendered.isEmpty {
            let maxLength = rendered.map { $0.hasPrefix("-") ? $0.count - 1 : $0.count }.max() ?? 0
            rendered = rendered.map { value in
                let isNegative = value.hasPrefix("-")
                let absolute = isNegative ? String(value.dropFirst()) : value
                let padded = String(repeating: "0", count: max(0, maxLength - absolute.count)) + absolute
                return isNegative ? "-" + padded : padded
            }
        }

        context.writeStdout(rendered.joined(separator: separator))
        if !rendered.isEmpty {
            context.writeStdout("\n")
        }
        return 0
    }

    private static func formatNumber(_ value: Double, precision: Int) -> String {
        if precision > 0 {
            return String(format: "%.\(precision)f", value)
        }

        let rounded = value.rounded()
        if abs(value - rounded) < 1e-9 {
            return String(Int(rounded))
        }
        return String(value)
    }

    private static func decimalPrecision(_ value: String) -> Int {
        let lowercased = value.lowercased()
        let mantissa = lowercased.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(lowercased)
        guard let dotIndex = mantissa.firstIndex(of: ".") else {
            return 0
        }
        return mantissa.distance(from: mantissa.index(after: dotIndex), to: mantissa.endIndex)
    }
}

struct SleepCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Duration(s), with optional suffix s/m/h/d")
        var durations: [String] = []
    }

    static let name = "sleep"
    static let overview = "Delay for a specified amount of time"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        guard !options.durations.isEmpty else {
            context.writeStderr("sleep: missing operand\n")
            return 1
        }

        var totalSeconds = 0.0
        for token in options.durations {
            guard let seconds = parseDuration(token) else {
                context.writeStderr("sleep: invalid time interval '\(token)'\n")
                return 1
            }
            totalSeconds += seconds
        }

        let nanosDouble = max(0, totalSeconds) * 1_000_000_000
        let nanos = UInt64(min(nanosDouble, Double(UInt64.max)))
        try? await Task.sleep(nanoseconds: nanos)
        return 0
    }

    private static func parseDuration(_ token: String) -> Double? {
        guard !token.isEmpty else {
            return nil
        }

        let suffix = token.last
        let multiplier: Double
        let numberPart: Substring

        switch suffix {
        case "s":
            multiplier = 1
            numberPart = token.dropLast()
        case "m":
            multiplier = 60
            numberPart = token.dropLast()
        case "h":
            multiplier = 60 * 60
            numberPart = token.dropLast()
        case "d":
            multiplier = 24 * 60 * 60
            numberPart = token.dropLast()
        default:
            multiplier = 1
            numberPart = Substring(token)
        }

        guard let value = Double(numberPart), value >= 0 else {
            return nil
        }
        return value * multiplier
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
        @Flag(name: .short, help: "List all matches in PATH order")
        var a = false

        @Flag(name: .short, help: "Do not print anything, just set status")
        var s = false

        @Argument(help: "Command names")
        var names: [String] = []
    }

    static let name = "which"
    static let overview = "Locate a command"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.names.isEmpty else {
            return 1
        }

        let searchPaths = (context.environment["PATH"] ?? "/bin:/usr/bin")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        var allFound = true

        for name in options.names {
            let matches = await resolveMatches(
                for: name,
                searchPaths: searchPaths,
                currentDirectory: context.currentDirectory,
                filesystem: context.filesystem,
                includeAll: options.a
            )

            if matches.isEmpty {
                allFound = false
                continue
            }

            if !options.s {
                for match in matches {
                    context.writeStdout("\(match)\n")
                }
            }
        }

        return allFound ? 0 : 1
    }

    private static func resolveMatches(
        for name: String,
        searchPaths: [String],
        currentDirectory: String,
        filesystem: any ShellFilesystem,
        includeAll: Bool
    ) async -> [String] {
        if name.contains("/") {
            let resolved = PathUtils.normalize(path: name, currentDirectory: currentDirectory)
            return await filesystem.exists(path: resolved) ? [resolved] : []
        }

        var matches: [String] = []
        for path in searchPaths {
            let normalizedPath = PathUtils.normalize(path: path, currentDirectory: currentDirectory)
            let candidate = PathUtils.join(normalizedPath, name)
            if await filesystem.exists(path: candidate) {
                matches.append(candidate)
                if !includeAll {
                    break
                }
            }
        }
        return matches
    }
}
