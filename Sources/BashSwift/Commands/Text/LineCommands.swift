import ArgumentParser
import Foundation

struct HeadCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Print the first N lines")
        var n: Int = 10

        @Option(name: .short, help: "Print the first N bytes")
        var c: Int?

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "head"
    static let overview = "Output the first part of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
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
            for file in options.files {
                do {
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
            if options.files.count > 1 {
                context.writeStdout("==> \(options.files[index]) <==\n")
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
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
        var n: Int = 10

        @Option(name: .short, help: "Print the last N bytes")
        var c: Int?

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "tail"
    static let overview = "Output the last part of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
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
            for file in options.files {
                do {
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
            if options.files.count > 1 {
                context.writeStdout("==> \(options.files[index]) <==\n")
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.suffix(max(options.n, 0)) {
                context.writeStdout("\(line)\n")
            }
        }
        return inputs.hadError ? 1 : 0
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

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "wc"
    static let overview = "Print newline, word, and byte counts"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let showAll = !options.l && !options.w && !options.c

        var totalLines = 0
        var totalWords = 0
        var totalBytes = 0

        for (index, content) in inputs.contents.enumerated() {
            let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
            let wordCount = content.split { $0.isWhitespace }.count
            let byteCount = content.lengthOfBytes(using: .utf8)

            totalLines += lineCount
            totalWords += wordCount
            totalBytes += byteCount

            var values: [String] = []
            if showAll || options.l { values.append("\(lineCount)") }
            if showAll || options.w { values.append("\(wordCount)") }
            if showAll || options.c { values.append("\(byteCount)") }

            let suffix = options.files.isEmpty ? "" : " \(options.files[index])"
            context.writeStdout(values.joined(separator: " ") + suffix + "\n")
        }

        if inputs.contents.count > 1 {
            var values: [String] = []
            if showAll || options.l { values.append("\(totalLines)") }
            if showAll || options.w { values.append("\(totalWords)") }
            if showAll || options.c { values.append("\(totalBytes)") }
            context.writeStdout(values.joined(separator: " ") + " total\n")
        }

        return inputs.hadError ? 1 : 0
    }
}

