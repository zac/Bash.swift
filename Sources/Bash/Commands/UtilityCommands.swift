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
        @Flag(name: .shortAndLong, help: "Show command overviews")
        var verbose = false

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
        context.writeStdout("Available commands (use '<command> --help' or '<command> -h' for usage):\n")
        let longestName = commands.map(\.count).max() ?? 0
        for command in commands {
            if options.verbose {
                let overview = context.commandRegistry[command]?.overview ?? ""
                let padding = String(repeating: " ", count: max(0, longestName - command.count))
                context.writeStdout("\(command)\(padding)  \(overview)\n")
            } else {
                context.writeStdout("\(command)\n")
            }
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

struct JobsCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "jobs"
    static let overview = "List background jobs"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = options
        guard context.supportsJobControl else {
            context.writeStderr("jobs: job control is unavailable\n")
            return 1
        }

        let jobs = await context.listJobs()
        for job in jobs {
            context.writeStdout("[\(job.id)] \(job.pid) \(displayState(job.state)) \(job.commandLine)\n")
        }

        return 0
    }

    private static func displayState(_ state: ShellJobState) -> String {
        switch state {
        case .running:
            return "Running"
        case let .done(exitCode):
            return exitCode == 0 ? "Done" : "Done(\(exitCode))"
        }
    }
}

struct FgCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional job spec (for example: %1)")
        var job: String?
    }

    static let name = "fg"
    static let overview = "Bring a background job to the foreground"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard context.supportsJobControl else {
            context.writeStderr("fg: job control is unavailable\n")
            return 1
        }

        let requestedID: Int?
        if let raw = options.job {
            guard let parsed = parseJobID(raw) else {
                context.writeStderr("fg: invalid job spec '\(raw)'\n")
                return 1
            }

            guard await context.hasJob(id: parsed) else {
                context.writeStderr("fg: %\(parsed): no such job\n")
                return 1
            }

            requestedID = parsed
        } else {
            guard await context.hasJobs() else {
                context.writeStderr("fg: no current job\n")
                return 1
            }
            requestedID = nil
        }

        guard let completion = await context.foregroundJob(id: requestedID) else {
            context.writeStderr("fg: failed to foreground job\n")
            return 1
        }

        context.stdout.append(completion.result.stdout)
        context.stderr.append(completion.result.stderr)
        return completion.result.exitCode
    }
}

struct WaitCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional job specs (for example: %1)")
        var jobs: [String] = []
    }

    static let name = "wait"
    static let overview = "Wait for background jobs to complete"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard context.supportsJobControl else {
            context.writeStderr("wait: job control is unavailable\n")
            return 1
        }

        if options.jobs.isEmpty {
            let completions = await context.waitForAllJobs()
            return completions.last?.result.exitCode ?? 0
        }

        var lastExitCode: Int32 = 0
        for raw in options.jobs {
            guard let id = parseJobID(raw) else {
                context.writeStderr("wait: invalid job spec '\(raw)'\n")
                return 1
            }

            guard await context.hasJob(id: id) else {
                context.writeStderr("wait: %\(id): no such job\n")
                return 127
            }

            guard let completion = await context.waitForJob(id: id) else {
                context.writeStderr("wait: %\(id): no such job\n")
                return 127
            }

            lastExitCode = completion.result.exitCode
        }

        return lastExitCode
    }
}

struct PsCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Compatibility flag (no-op in emulated mode)")
        var e = false

        @Flag(name: .short, help: "Compatibility flag (no-op in emulated mode)")
        var f = false

        @Flag(name: .short, help: "Compatibility flag (no-op in emulated mode)")
        var a = false

        @Flag(name: .short, help: "Compatibility flag (no-op in emulated mode)")
        var x = false

        @Option(name: .short, parsing: .upToNextOption, help: "Filter by pseudo-PID")
        var p: [String] = []

        @Argument(help: "Compatibility tokens such as 'aux'")
        var compatibility: [String] = []
    }

    static let name = "ps"
    static let overview = "List emulated background processes"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard context.supportsJobControl else {
            context.writeStderr("ps: process table is unavailable\n")
            return 1
        }

        let invalidCompat = options.compatibility.first { token in
            let normalized = token.lowercased()
            return normalized != "aux" && normalized != "ax"
        }
        if let invalidCompat {
            context.writeStderr("ps: unsupported argument '\(invalidCompat)'\n")
            return 1
        }

        let requestedPIDs = parsePIDFilters(options.p)
        if requestedPIDs.invalid {
            context.writeStderr("ps: invalid pid list\n")
            return 1
        }

        let snapshots = await context.listJobs()
        let indexed = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        let filtered: [ShellJobSnapshot]
        var missing: [Int] = []

        if requestedPIDs.values.isEmpty {
            filtered = snapshots
        } else {
            var collected: [ShellJobSnapshot] = []
            for pid in requestedPIDs.values.sorted() {
                if let snapshot = indexed[pid] {
                    collected.append(snapshot)
                } else {
                    missing.append(pid)
                }
            }
            filtered = collected
        }

        context.writeStdout("PID JOB STAT COMMAND\n")
        for snapshot in filtered {
            let line = "\(snapshot.pid) \(snapshot.id) \(displayStatus(snapshot.state)) \(snapshot.commandLine)\n"
            context.writeStdout(line)
        }

        if !missing.isEmpty {
            for pid in missing {
                context.writeStderr("ps: \(pid): no such process\n")
            }
            return 1
        }

        return 0
    }

    private static func displayStatus(_ state: ShellJobState) -> String {
        switch state {
        case .running:
            return "R"
        case .done:
            return "Z"
        }
    }
}

struct KillCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "Targets and optional signal flags")
        var args: [String] = []
    }

    static let name = "kill"
    static let overview = "Send a signal to emulated background processes"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.args == ["--help"] || options.args == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Send a signal to emulated background processes

                USAGE: kill [-s SIGNAL | -SIGNAL] <pid|%job>...
                  or:  kill -l [signal_number ...]

                """
            )
            return 0
        }

        guard context.supportsJobControl else {
            context.writeStderr("kill: process table is unavailable\n")
            return 1
        }

        let parsed = parseKillArguments(options.args)
        switch parsed {
        case let .failure(message):
            context.writeStderr("kill: \(message)\n")
            return 1
        case let .listSignals(values):
            if values.isEmpty {
                context.writeStdout(supportedSignalsLine + "\n")
                return 0
            }

            for value in values {
                guard let number = Int32(value), number >= 0 else {
                    context.writeStderr("kill: \(value): invalid signal number\n")
                    return 1
                }

                guard let resolved = signalName(for: number) else {
                    context.writeStderr("kill: \(value): invalid signal number\n")
                    return 1
                }

                context.writeStdout("\(resolved)\n")
            }
            return 0
        case let .signal(signal, targets):
            guard !targets.isEmpty else {
                context.writeStderr("usage: kill [-s signal | -signal] pid | %job ...\n")
                return 1
            }

            var allFound = true
            for target in targets {
                if target.hasPrefix("%") {
                    guard let jobID = parseJobID(target) else {
                        context.writeStderr("kill: \(target): invalid job spec\n")
                        allFound = false
                        continue
                    }

                    let terminated = await context.terminateJob(id: jobID, signal: signal)
                    if !terminated {
                        context.writeStderr("kill: \(target): no such job\n")
                        allFound = false
                    }
                } else {
                    guard let pid = parsePID(target) else {
                        context.writeStderr("kill: \(target): invalid pid\n")
                        allFound = false
                        continue
                    }

                    let terminated = await context.terminateProcess(pid: pid, signal: signal)
                    if !terminated {
                        context.writeStderr("kill: \(pid): no such process\n")
                        allFound = false
                    }
                }
            }

            return allFound ? 0 : 1
        }
    }

    private enum ParsedKillInvocation {
        case failure(String)
        case listSignals([String])
        case signal(Int32, [String])
    }

    private static func parseKillArguments(_ args: [String]) -> ParsedKillInvocation {
        var index = 0
        var signal: Int32 = 15
        var targets: [String] = []
        var listSignals = false
        var listSignalValues: [String] = []
        var parseOptions = true

        while index < args.count {
            let token = args[index]

            if parseOptions, token == "--" {
                parseOptions = false
                index += 1
                continue
            }

            if parseOptions, token == "-l" || token == "--list" {
                listSignals = true
                index += 1
                continue
            }

            if parseOptions, token == "-s" || token == "--signal" {
                let next = index + 1
                guard next < args.count else {
                    return .failure("option requires an argument -- s")
                }

                guard let parsed = parseSignalToken(args[next]) else {
                    return .failure("invalid signal '\(args[next])'")
                }
                signal = parsed
                index += 2
                continue
            }

            if parseOptions, token.hasPrefix("-"), token.count > 1 {
                let candidate = String(token.dropFirst())
                if let parsed = parseSignalToken(candidate) {
                    signal = parsed
                    index += 1
                    continue
                }
            }

            if listSignals, token != "-l", token != "--list" {
                listSignalValues.append(token)
            } else {
                targets.append(token)
            }
            index += 1
        }

        if listSignals {
            return .listSignals(listSignalValues)
        }

        return .signal(signal, targets)
    }
}

private func parseJobID(_ raw: String) -> Int? {
    guard !raw.isEmpty else {
        return nil
    }

    let token: Substring
    if raw.hasPrefix("%") {
        token = raw.dropFirst()
        guard !token.isEmpty else {
            return nil
        }
    } else {
        token = Substring(raw)
    }

    guard let id = Int(token), id > 0 else {
        return nil
    }

    return id
}

private func parsePID(_ raw: String) -> Int? {
    guard let pid = Int(raw), pid > 0 else {
        return nil
    }
    return pid
}

private func parsePIDFilters(_ rawValues: [String]) -> (values: Set<Int>, invalid: Bool) {
    var values: Set<Int> = []

    for token in rawValues {
        for rawPart in token.split(separator: ",", omittingEmptySubsequences: true) {
            guard let parsed = parsePID(String(rawPart)) else {
                return ([], true)
            }
            values.insert(parsed)
        }
    }

    return (values, false)
}

private let supportedSignals: [(name: String, number: Int32)] = [
    ("HUP", 1),
    ("INT", 2),
    ("QUIT", 3),
    ("KILL", 9),
    ("TERM", 15),
    ("CONT", 18),
    ("STOP", 19),
]

private let supportedSignalsLine = supportedSignals.map(\.name).joined(separator: " ")

private func parseSignalToken(_ token: String) -> Int32? {
    if let number = Int32(token), number >= 0 {
        return number
    }

    let normalized = token.uppercased().hasPrefix("SIG")
        ? String(token.uppercased().dropFirst(3))
        : token.uppercased()

    return supportedSignals.first(where: { $0.name == normalized })?.number
}

private func signalName(for number: Int32) -> String? {
    supportedSignals.first(where: { $0.number == number })?.name
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
