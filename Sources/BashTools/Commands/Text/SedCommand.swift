import ArgumentParser
import Foundation
import BashCore

struct SedCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Suppress automatic printing")
        var n = false

        @Flag(name: .short, help: "Use extended regular expressions")
        var E = false

        @Flag(name: .short, help: "Edit files in place")
        var i = false

        @Option(name: .short, help: "Add script to the commands to be executed")
        var e: [String] = []

        @Argument(help: "Script and optional files")
        var values: [String] = []
    }

    static let name = "sed"
    static let overview = "Stream editor"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = options.E

        let scripts: [String]
        let files: [String]
        if !options.e.isEmpty {
            scripts = options.e
            files = options.values
        } else {
            guard let first = options.values.first else {
                context.writeStderr("sed: missing script\n")
                return 2
            }
            scripts = [first]
            files = Array(options.values.dropFirst())
        }

        guard !scripts.isEmpty else {
            context.writeStderr("sed: missing script\n")
            return 2
        }

        let commands: [Command]
        do {
            commands = try parseCommands(from: scripts)
        } catch let error as ShellError {
            context.writeStderr("sed: \(error)\n")
            return 2
        } catch {
            context.writeStderr("sed: unsupported script\n")
            return 2
        }

        if options.i, files.isEmpty {
            context.writeStderr("sed: -i requires at least one file\n")
            return 2
        }

        if files.isEmpty {
            let output = processContent(
                CommandIO.decodeString(context.stdin),
                commands: commands,
                suppressDefaultPrint: options.n
            )
            context.writeStdout(output)
            return 0
        }

        var failed = false
        for file in files {
            do {
                let resolved = context.resolvePath(file)
                let data = try await context.filesystem.readFile(path: resolved)
                let content = CommandIO.decodeString(data)
                let output = processContent(content, commands: commands, suppressDefaultPrint: options.n)

                if options.i {
                    try await context.filesystem.writeFile(path: resolved, data: CommandIO.encode(output), append: false)
                } else {
                    context.writeStdout(output)
                }
            } catch {
                context.writeStderr("sed: \(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    private enum Address {
        case line(Int)
        case regex(NSRegularExpression)

        func matches(line: String, lineNumber: Int) -> Bool {
            switch self {
            case let .line(expected):
                return lineNumber == expected
            case let .regex(regex):
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return regex.firstMatch(in: line, range: range) != nil
            }
        }
    }

    private struct AddressRange {
        let start: Address
        let end: Address?
        var isActive = false

        mutating func applies(line: String, lineNumber: Int) -> Bool {
            if let end {
                if !isActive, start.matches(line: line, lineNumber: lineNumber) {
                    isActive = true
                }

                if isActive {
                    let shouldReset = end.matches(line: line, lineNumber: lineNumber)
                    if shouldReset {
                        isActive = false
                    }
                    return true
                }

                return false
            }

            return start.matches(line: line, lineNumber: lineNumber)
        }
    }

    private struct Substitution {
        var address: AddressRange?
        let regex: NSRegularExpression
        let replacement: String
        let global: Bool
        let printAfterMatch: Bool
    }

    private struct PrintCommand {
        var address: AddressRange?
    }

    private enum Command {
        case substitution(Substitution)
        case print(PrintCommand)
    }

    private static func parseCommands(from scripts: [String]) throws -> [Command] {
        var commands: [Command] = []
        for script in scripts {
            let parts = splitScripts(script)
            for part in parts where !part.isEmpty {
                commands.append(try parseCommand(part))
            }
        }
        return commands
    }

    private static func splitScripts(_ script: String) -> [String] {
        script.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func parseCommand(_ source: String) throws -> Command {
        var script = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = try parseAddressPrefix(script: &script)
        guard let opcode = script.first else {
            throw ShellError.unsupported("invalid script")
        }

        switch opcode {
        case "s":
            return .substitution(try parseSubstitution(script, address: address))
        case "p":
            return .print(PrintCommand(address: address))
        default:
            throw ShellError.unsupported("unsupported command")
        }
    }

    private static func parseSubstitution(_ script: String, address: AddressRange?) throws -> Substitution {
        guard script.first == "s", script.count >= 2 else {
            throw ShellError.unsupported("only substitution scripts are supported")
        }

        let delimiter = script[script.index(after: script.startIndex)]
        var index = script.index(script.startIndex, offsetBy: 2)

        let pattern = try parseSegment(script, delimiter: delimiter, index: &index)
        let replacement = try parseSegment(script, delimiter: delimiter, index: &index)
        let flags = String(script[index...])

        let validFlags = Set(flags)
        guard validFlags.subtracting(["g", "p"]).isEmpty else {
            throw ShellError.unsupported("unsupported substitution flag")
        }

        let regex = try NSRegularExpression(pattern: pattern)
        return Substitution(
            address: address,
            regex: regex,
            replacement: replacement,
            global: flags.contains("g"),
            printAfterMatch: flags.contains("p")
        )
    }

    private static func parseAddressPrefix(script: inout String) throws -> AddressRange? {
        var index = script.startIndex
        guard let first = try parseSingleAddress(script, index: &index) else {
            return nil
        }

        var second: Address?
        if index < script.endIndex, script[index] == "," {
            index = script.index(after: index)
            second = try parseSingleAddress(script, index: &index)
            if second == nil {
                throw ShellError.unsupported("invalid address range")
            }
        }

        script = String(script[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return AddressRange(start: first, end: second, isActive: false)
    }

    private static func parseSingleAddress(_ script: String, index: inout String.Index) throws -> Address? {
        while index < script.endIndex, script[index].isWhitespace {
            index = script.index(after: index)
        }

        guard index < script.endIndex else {
            return nil
        }

        if script[index].isNumber {
            let start = index
            while index < script.endIndex, script[index].isNumber {
                index = script.index(after: index)
            }
            let token = String(script[start..<index])
            guard let number = Int(token) else {
                throw ShellError.unsupported("invalid address")
            }
            return .line(number)
        }

        if script[index] == "/" {
            index = script.index(after: index)
            var pattern = ""
            var escaped = false

            while index < script.endIndex {
                let char = script[index]
                index = script.index(after: index)

                if escaped {
                    pattern.append(char)
                    escaped = false
                    continue
                }

                if char == "\\" {
                    escaped = true
                    continue
                }

                if char == "/" {
                    return .regex(try NSRegularExpression(pattern: pattern))
                }

                pattern.append(char)
            }

            throw ShellError.unsupported("unterminated regex address")
        }

        return nil
    }

    private static func parseSegment(
        _ script: String,
        delimiter: Character,
        index: inout String.Index
    ) throws -> String {
        guard index <= script.endIndex else {
            throw ShellError.unsupported("invalid substitution script")
        }

        var segment = ""
        var escaped = false
        while index < script.endIndex {
            let character = script[index]
            index = script.index(after: index)

            if escaped {
                if character == delimiter || character == "\\" {
                    segment.append(character)
                } else {
                    segment.append("\\")
                    segment.append(character)
                }
                escaped = false
                continue
            }

            if character == "\\" {
                escaped = true
                continue
            }

            if character == delimiter {
                return segment
            }

            segment.append(character)
        }

        if escaped {
            segment.append("\\")
        }

        throw ShellError.unsupported("invalid substitution script")
    }

    private static func replace(line: String, using substitution: Substitution) -> String {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        if substitution.global {
            return substitution.regex.stringByReplacingMatches(
                in: line,
                range: fullRange,
                withTemplate: substitution.replacement
            )
        }

        guard let match = substitution.regex.firstMatch(in: line, range: fullRange) else {
            return line
        }

        let prefixRange = NSRange(location: 0, length: match.range.location)
        let suffixLocation = match.range.location + match.range.length
        let suffixRange = NSRange(location: suffixLocation, length: max(0, fullRange.length - suffixLocation))
        let source = line as NSString
        let replacement = substitution.regex.replacementString(
            for: match,
            in: line,
            offset: 0,
            template: substitution.replacement
        )

        return source.substring(with: prefixRange) + replacement + source.substring(with: suffixRange)
    }

    private static func lines(from content: String) -> [String] {
        if content.isEmpty {
            return []
        }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if content.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func processContent(_ content: String, commands: [Command], suppressDefaultPrint: Bool) -> String {
        let inputLines = lines(from: content)
        var outputLines: [String] = []

        var workingCommands = commands
        for (lineIndex, originalLine) in inputLines.enumerated() {
            let lineNumber = lineIndex + 1
            var line = originalLine
            var explicitPrints: [String] = []

            for index in workingCommands.indices {
                switch workingCommands[index] {
                case var .substitution(substitution):
                    let applies = substitution.address?.applies(line: line, lineNumber: lineNumber) ?? true
                    guard applies else { continue }

                    let replaced = replace(line: line, using: substitution)
                    if substitution.printAfterMatch, replaced != line {
                        explicitPrints.append(replaced)
                    }
                    line = replaced
                    workingCommands[index] = .substitution(substitution)
                case var .print(printCommand):
                    let applies = printCommand.address?.applies(line: line, lineNumber: lineNumber) ?? true
                    if applies {
                        explicitPrints.append(line)
                    }
                    workingCommands[index] = .print(printCommand)
                }
            }

            if !suppressDefaultPrint {
                outputLines.append(line)
            }
            outputLines.append(contentsOf: explicitPrints)
        }

        if outputLines.isEmpty {
            return ""
        }

        return outputLines.joined(separator: "\n") + "\n"
    }
}
