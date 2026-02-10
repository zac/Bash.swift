import ArgumentParser
import Foundation

struct HeadCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Print the first N lines")
        var n: Int = 10

        @Option(name: .short, help: "Print the first N bytes")
        var c: Int?

        @Flag(name: .short, help: "Never print file headers")
        var q = false

        @Flag(name: .short, help: "Always print file headers")
        var v = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "head"
    static let overview = "Output the first part of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.n >= 0 else {
            context.writeStderr("head: line count must be >= 0\n")
            return 1
        }

        if let bytes = options.c {
            guard bytes >= 0 else {
                context.writeStderr("head: byte count must be >= 0\n")
                return 1
            }

            if options.files.isEmpty {
                context.stdout.append(context.stdin.prefix(bytes))
                return 0
            }

            var failed = false
            for (index, file) in options.files.enumerated() {
                do {
                    if shouldShowHeader(totalFiles: options.files.count, quiet: options.q, verbose: options.v) {
                        if index > 0 {
                            context.writeStdout("\n")
                        }
                        context.writeStdout("==> \(file) <==\n")
                    }
                    let data = try await context.filesystem.readFile(path: context.resolvePath(file))
                    context.stdout.append(data.prefix(bytes))
                } catch {
                    context.writeStderr("head: \(file): \(error)\n")
                    failed = true
                }
            }
            return failed ? 1 : 0
        }

        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        for (index, content) in inputs.contents.enumerated() {
            if shouldShowHeader(totalFiles: options.files.count, quiet: options.q, verbose: options.v) {
                if index > 0 {
                    context.writeStdout("\n")
                }
                context.writeStdout("==> \(options.files[index]) <==\n")
            }
            let lines = CommandIO.splitLines(content)
            for line in lines.prefix(max(options.n, 0)) {
                context.writeStdout("\(line)\n")
            }
        }
        return inputs.hadError ? 1 : 0
    }
}

struct TailCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Print the last N lines")
        var n: String = "10"

        @Option(name: .short, help: "Print the last N bytes")
        var c: Int?

        @Flag(name: .short, help: "Never print file headers")
        var q = false

        @Flag(name: .short, help: "Always print file headers")
        var v = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "tail"
    static let overview = "Output the last part of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard let lineMode = parseLineMode(options.n) else {
            context.writeStderr("tail: invalid number of lines: \(options.n)\n")
            return 1
        }

        if let bytes = options.c {
            guard bytes >= 0 else {
                context.writeStderr("tail: byte count must be >= 0\n")
                return 1
            }

            if options.files.isEmpty {
                context.stdout.append(context.stdin.suffix(bytes))
                return 0
            }

            var failed = false
            for (index, file) in options.files.enumerated() {
                do {
                    if shouldShowHeader(totalFiles: options.files.count, quiet: options.q, verbose: options.v) {
                        if index > 0 {
                            context.writeStdout("\n")
                        }
                        context.writeStdout("==> \(file) <==\n")
                    }
                    let data = try await context.filesystem.readFile(path: context.resolvePath(file))
                    context.stdout.append(data.suffix(bytes))
                } catch {
                    context.writeStderr("tail: \(file): \(error)\n")
                    failed = true
                }
            }
            return failed ? 1 : 0
        }

        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        for (index, content) in inputs.contents.enumerated() {
            if shouldShowHeader(totalFiles: options.files.count, quiet: options.q, verbose: options.v) {
                if index > 0 {
                    context.writeStdout("\n")
                }
                context.writeStdout("==> \(options.files[index]) <==\n")
            }
            let lines = CommandIO.splitLines(content)
            let output: ArraySlice<String>
            switch lineMode {
            case .last(let count):
                output = lines.suffix(count)
            case .from(let startLine):
                output = lines.dropFirst(startLine - 1)
            }

            for line in output {
                context.writeStdout("\(line)\n")
            }
        }
        return inputs.hadError ? 1 : 0
    }

    private enum LineMode {
        case last(Int)
        case from(Int)
    }

    private static func parseLineMode(_ raw: String) -> LineMode? {
        if raw.hasPrefix("+") {
            let value = String(raw.dropFirst())
            guard let numeric = Int(value), numeric > 0 else {
                return nil
            }
            return .from(numeric)
        }

        guard let numeric = Int(raw), numeric >= 0 else {
            return nil
        }
        return .last(numeric)
    }
}

struct WcCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Print line counts")
        var l = false

        @Flag(name: .short, help: "Print word counts")
        var w = false

        @Flag(name: .short, help: "Print byte counts")
        var c = false

        @Flag(name: [.short, .customLong("chars")], help: "Print character counts")
        var m = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "wc"
    static let overview = "Print newline, word, and byte counts"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let showAll = !options.l && !options.w && !options.c && !options.m

        var totalLines = 0
        var totalWords = 0
        var totalBytes = 0
        var totalChars = 0

        for (index, content) in inputs.contents.enumerated() {
            let lineCount = content.reduce(into: 0) { partialResult, character in
                if character == "\n" {
                    partialResult += 1
                }
            }
            let wordCount = content.split { $0.isWhitespace }.count
            let byteCount = content.lengthOfBytes(using: .utf8)
            let charCount = content.count

            totalLines += lineCount
            totalWords += wordCount
            totalBytes += byteCount
            totalChars += charCount

            var values: [String] = []
            if showAll || options.l { values.append("\(lineCount)") }
            if showAll || options.w { values.append("\(wordCount)") }
            if showAll || options.c { values.append("\(byteCount)") }
            if options.m { values.append("\(charCount)") }

            let suffix = options.files.isEmpty ? "" : " \(options.files[index])"
            context.writeStdout(values.joined(separator: " ") + suffix + "\n")
        }

        if inputs.contents.count > 1 {
            var values: [String] = []
            if showAll || options.l { values.append("\(totalLines)") }
            if showAll || options.w { values.append("\(totalWords)") }
            if showAll || options.c { values.append("\(totalBytes)") }
            if options.m { values.append("\(totalChars)") }
            context.writeStdout(values.joined(separator: " ") + " total\n")
        }

        return inputs.hadError ? 1 : 0
    }
}

private func shouldShowHeader(totalFiles: Int, quiet: Bool, verbose: Bool) -> Bool {
    if quiet {
        return false
    }

    return verbose || totalFiles > 1
}
