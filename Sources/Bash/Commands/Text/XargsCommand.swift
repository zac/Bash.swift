import ArgumentParser
import Foundation

struct XargsCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "Arguments")
        var arguments: [String] = []
    }

    static let name = "xargs"
    static let overview = "Build and execute command lines from standard input"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.arguments.contains("--help") || options.arguments.contains("-h") {
            context.writeStdout(
                """
                OVERVIEW: Build and execute command lines from standard input
                
                USAGE: xargs [OPTION]... [COMMAND [INITIAL-ARGS]]
                
                OPTIONS:
                  -I REPLACE            replace occurrences of REPLACE with input
                  -d DELIM              use DELIM as input delimiter (for example: -d '\\n')
                  -n NUM                use at most NUM arguments per command line
                  -L NUM                use at most NUM input lines per command line
                  -E STR                stop processing at line matching STR
                  -P NUM                run at most NUM commands at a time
                  -0, --null            items are separated by NUL, not whitespace
                  -t, --verbose         print commands before executing them
                  -r, --no-run-if-empty do not run command if input is empty
                
                """
            )
            return 0
        }

        let parsed = parseInvocation(options.arguments)
        switch parsed {
        case let .failure(message):
            context.writeStderr(message)
            return 1
        case let .success(invocation):
            return await execute(invocation: invocation, context: &context)
        }
    }

    private struct Invocation: Sendable {
        var replace: String?
        var delimiter: String?
        var maxArgs: Int?
        var maxLines: Int?
        var maxProcs: Int?
        var eof: String?
        var nullSeparated: Bool
        var verbose: Bool
        var noRunIfEmpty: Bool
        var command: [String]
    }

    private enum ParseOutcome {
        case success(Invocation)
        case failure(String)
    }

    private static func parseInvocation(_ args: [String]) -> ParseOutcome {
        var replace: String?
        var delimiter: String?
        var maxArgs: Int?
        var maxLines: Int?
        var maxProcs: Int?
        var eof: String?
        var nullSeparated = false
        var verbose = false
        var noRunIfEmpty = false
        var commandStart = args.count

        var index = 0
        while index < args.count {
            let arg = args[index]

            if arg == "-I" {
                guard index + 1 < args.count else {
                    return .failure("xargs: option requires an argument -- I\n")
                }
                replace = args[index + 1]
                index += 2
                continue
            }

            if arg == "-d" {
                guard index + 1 < args.count else {
                    return .failure("xargs: option requires an argument -- d\n")
                }
                delimiter = decodeDelimiter(args[index + 1])
                index += 2
                continue
            }

            if arg == "-n" {
                guard index + 1 < args.count else {
                    return .failure("xargs: option requires an argument -- n\n")
                }
                guard let value = Int(args[index + 1]), value > 0 else {
                    return .failure("xargs: invalid number for -n: \(args[index + 1])\n")
                }
                maxArgs = value
                index += 2
                continue
            }

            if arg == "-L" || arg == "--max-lines" {
                guard index + 1 < args.count else {
                    return .failure("xargs: option requires an argument -- L\n")
                }
                guard let value = Int(args[index + 1]), value > 0 else {
                    return .failure("xargs: invalid number for -L: \(args[index + 1])\n")
                }
                maxLines = value
                index += 2
                continue
            }

            if let value = parseEqualsOption(argument: arg, prefix: "--max-lines=") {
                guard let numeric = Int(value), numeric > 0 else {
                    return .failure("xargs: invalid number for -L: \(value)\n")
                }
                maxLines = numeric
                index += 1
                continue
            }

            if arg == "-P" {
                guard index + 1 < args.count else {
                    return .failure("xargs: option requires an argument -- P\n")
                }
                guard let value = Int(args[index + 1]), value > 0 else {
                    return .failure("xargs: invalid number for -P: \(args[index + 1])\n")
                }
                maxProcs = value
                index += 2
                continue
            }

            if arg == "-E" || arg == "--eof" {
                guard index + 1 < args.count else {
                    return .failure("xargs: option requires an argument -- E\n")
                }
                eof = args[index + 1]
                index += 2
                continue
            }

            if let value = parseEqualsOption(argument: arg, prefix: "--eof=") {
                eof = value
                index += 1
                continue
            }

            if arg == "-0" || arg == "--null" {
                nullSeparated = true
                index += 1
                continue
            }

            if arg == "-t" || arg == "--verbose" {
                verbose = true
                index += 1
                continue
            }

            if arg == "-r" || arg == "--no-run-if-empty" {
                noRunIfEmpty = true
                index += 1
                continue
            }

            if arg.hasPrefix("--") {
                return .failure("xargs: unrecognized option '\(arg)'\n")
            }

            if arg.hasPrefix("-"), arg.count > 1 {
                var recognizedCombined = true
                for token in arg.dropFirst() {
                    switch token {
                    case "0":
                        nullSeparated = true
                    case "t":
                        verbose = true
                    case "r":
                        noRunIfEmpty = true
                    default:
                        recognizedCombined = false
                    }
                    if !recognizedCombined {
                        return .failure("xargs: invalid option -- \(token)\n")
                    }
                }
                index += 1
                continue
            }

            commandStart = index
            break
        }

        let command = commandStart < args.count ? Array(args[commandStart...]) : []
        return .success(
            Invocation(
                replace: replace,
                delimiter: delimiter,
                maxArgs: maxArgs,
                maxLines: maxLines,
                maxProcs: maxProcs,
                eof: eof,
                nullSeparated: nullSeparated,
                verbose: verbose,
                noRunIfEmpty: noRunIfEmpty,
                command: command
            )
        )
    }

    private static func execute(
        invocation: Invocation,
        context: inout CommandContext
    ) async -> Int32 {
        let items = parseItems(
            stdin: context.stdin,
            nullSeparated: invocation.nullSeparated,
            delimiter: invocation.delimiter,
            maxLines: invocation.maxLines,
            eof: invocation.eof
        )
        if items.isEmpty {
            if invocation.noRunIfEmpty {
                return 0
            }
            return 0
        }

        let command = invocation.command.isEmpty ? ["echo"] : invocation.command
        let invocations = buildInvocations(
            command: command,
            items: items,
            replace: invocation.replace,
            maxArgs: invocation.maxArgs,
            maxLines: invocation.maxLines
        )

        return await executeInvocations(
            invocations,
            maxProcs: invocation.maxProcs ?? 1,
            verbose: invocation.verbose,
            context: &context
        )
    }

    private static func parseItems(
        stdin: Data,
        nullSeparated: Bool,
        delimiter: String?,
        maxLines: Int?,
        eof: String?
    ) -> [String] {
        let output: [String]
        if nullSeparated {
            output = stdin
                .split(separator: 0, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
                .filter { !$0.isEmpty }
        } else {
            let input = CommandIO.decodeString(stdin)
            if let delimiter {
                var trimmed = input
                if trimmed.hasSuffix("\n") {
                    trimmed.removeLast()
                }
                output = trimmed
                    .components(separatedBy: delimiter)
                    .filter { !$0.isEmpty }
            } else if maxLines != nil {
                output = input
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { !$0.isEmpty }
            } else {
                output = input
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                    .filter { !$0.isEmpty }
            }
        }

        guard let eof else {
            return output
        }

        if let index = output.firstIndex(of: eof) {
            return Array(output[..<index])
        }

        return output
    }

    private static func buildInvocations(
        command: [String],
        items: [String],
        replace: String?,
        maxArgs: Int?,
        maxLines: Int?
    ) -> [[String]] {
        if let replace {
            return items.map { item in
                command.map { token in
                    token.replacingOccurrences(of: replace, with: item)
                }
            }
        }

        if let maxArgs {
            var output: [[String]] = []
            var index = 0
            while index < items.count {
                let end = min(index + maxArgs, items.count)
                output.append(command + items[index..<end])
                index = end
            }
            return output
        }

        if let maxLines {
            var output: [[String]] = []
            var index = 0
            while index < items.count {
                let end = min(index + maxLines, items.count)
                output.append(command + items[index..<end])
                index = end
            }
            return output
        }

        return [command + items]
    }

    private static func parseEqualsOption(argument: String, prefix: String) -> String? {
        guard argument.hasPrefix(prefix) else {
            return nil
        }
        return String(argument.dropFirst(prefix.count))
    }

    private static func executeInvocations(
        _ invocations: [[String]],
        maxProcs: Int,
        verbose: Bool,
        context: inout CommandContext
    ) async -> Int32 {
        var exitCode: Int32 = 0
        let baseContext = context

        if maxProcs <= 1 {
            for invocation in invocations {
                if verbose {
                    context.writeStderr(renderCommandLine(invocation) + "\n")
                }
                let result = await baseContext.runSubcommandIsolated(invocation, stdin: Data()).result
                context.stdout.append(result.stdout)
                context.stderr.append(result.stderr)
                if result.exitCode != 0 {
                    exitCode = result.exitCode
                }
            }
            return exitCode
        }

        var index = 0
        while index < invocations.count {
            let end = min(index + maxProcs, invocations.count)
            let batch = Array(invocations[index..<end])

            if verbose {
                for invocation in batch {
                    context.writeStderr(renderCommandLine(invocation) + "\n")
                }
            }

            var orderedResults: [CommandResult?] = Array(repeating: nil, count: batch.count)
            await withTaskGroup(of: (Int, CommandResult).self) { group in
                for (offset, invocation) in batch.enumerated() {
                    group.addTask {
                        let outcome = await baseContext.runSubcommandIsolated(invocation, stdin: Data())
                        return (offset, outcome.result)
                    }
                }

                for await (offset, result) in group {
                    orderedResults[offset] = result
                }
            }

            for result in orderedResults.compactMap({ $0 }) {
                context.stdout.append(result.stdout)
                context.stderr.append(result.stderr)
                if result.exitCode != 0 {
                    exitCode = result.exitCode
                }
            }

            index = end
        }

        return exitCode
    }

    private static func decodeDelimiter(_ raw: String) -> String {
        var output = ""
        var escaping = false

        for char in raw {
            if escaping {
                switch char {
                case "n":
                    output.append("\n")
                case "t":
                    output.append("\t")
                case "r":
                    output.append("\r")
                case "0":
                    output.append("\0")
                case "\\":
                    output.append("\\")
                default:
                    output.append(char)
                }
                escaping = false
                continue
            }

            if char == "\\" {
                escaping = true
                continue
            }

            output.append(char)
        }

        if escaping {
            output.append("\\")
        }

        return output
    }

    private static func renderCommandLine(_ argv: [String]) -> String {
        argv.map(quotedIfNeeded).joined(separator: " ")
    }

    private static func quotedIfNeeded(_ argument: String) -> String {
        if argument.isEmpty {
            return "\"\""
        }

        let shellSpecials = "\"'\\$`!*?[]{}();&|<>#"
        let needsQuotes = argument.contains(where: { char in
            char.isWhitespace || shellSpecials.contains(char)
        })

        guard needsQuotes else {
            return argument
        }

        let escaped = argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}
