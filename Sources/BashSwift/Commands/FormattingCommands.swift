import ArgumentParser
import Foundation

struct PrintfCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Format string")
        var format: String

        @Argument(help: "Values")
        var values: [String] = []
    }

    static let name = "printf"
    static let overview = "Format and print data"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let rendered = render(format: unescape(options.format), values: options.values)
        context.writeStdout(rendered)
        return 0
    }

    private static func render(format: String, values: [String]) -> String {
        var result = ""
        let characters = Array(format)
        var index = 0
        var valueIndex = 0

        func nextValue() -> String {
            guard valueIndex < values.count else {
                return ""
            }
            defer { valueIndex += 1 }
            return values[valueIndex]
        }

        while index < characters.count {
            let character = characters[index]
            if character != "%" {
                result.append(character)
                index += 1
                continue
            }

            index += 1
            guard index < characters.count else {
                result.append("%")
                break
            }

            let specifier = characters[index]
            switch specifier {
            case "%":
                result.append("%")
            case "s", "@":
                result.append(nextValue())
            case "d", "i":
                result.append(String(Int(nextValue()) ?? 0))
            case "f":
                result.append(String(Double(nextValue()) ?? 0))
            default:
                result.append("%")
                result.append(specifier)
            }
            index += 1
        }

        return result
    }

    private static func unescape(_ input: String) -> String {
        var result = ""
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            guard character == "\\" else {
                result.append(character)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                result.append("\\")
                break
            }

            switch input[next] {
            case "n":
                result.append("\n")
            case "t":
                result.append("\t")
            case "r":
                result.append("\r")
            case "\\":
                result.append("\\")
            default:
                result.append(input[next])
            }
            index = input.index(after: next)
        }

        return result
    }
}

struct Base64Command: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("d"), .long], help: "Decode data")
        var decode = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "base64"
    static let overview = "Base64 encode or decode data"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.files.isEmpty {
            return runSingleBuffer(context: &context, pathLabel: "-", data: context.stdin, decode: options.decode)
        }

        var failed = false
        for file in options.files {
            do {
                let data = try await context.filesystem.readFile(path: context.resolvePath(file))
                let exit = runSingleBuffer(context: &context, pathLabel: file, data: data, decode: options.decode)
                if exit != 0 {
                    failed = true
                }
            } catch {
                context.writeStderr("base64: \(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    private static func runSingleBuffer(
        context: inout CommandContext,
        pathLabel: String,
        data: Data,
        decode: Bool
    ) -> Int32 {
        if decode {
            let raw = String(decoding: data, as: UTF8.self)
            let compact = raw.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: compact) else {
                context.writeStderr("base64: \(pathLabel): invalid base64 input\n")
                return 1
            }
            context.stdout.append(decoded)
            return 0
        }

        context.writeStdout(data.base64EncodedString())
        context.writeStdout("\n")
        return 0
    }
}

private enum DigestCommandRunner {
    static func run(
        command: String,
        context: inout CommandContext,
        files: [String],
        digest: (Data) -> String
    ) async -> Int32 {
        if files.isEmpty {
            let hash = digest(context.stdin)
            context.writeStdout("\(hash)  -\n")
            return 0
        }

        var failed = false
        for file in files {
            do {
                let data = try await context.filesystem.readFile(path: context.resolvePath(file))
                context.writeStdout("\(digest(data))  \(file)\n")
            } catch {
                context.writeStderr("\(command): \(file): \(error)\n")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}

struct Sha256sumCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "sha256sum"
    static let overview = "Compute SHA-256 message digest"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await DigestCommandRunner.run(command: name, context: &context, files: options.files, digest: CommandHash.sha256)
    }
}

struct Sha1sumCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "sha1sum"
    static let overview = "Compute SHA-1 message digest"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await DigestCommandRunner.run(command: name, context: &context, files: options.files, digest: CommandHash.sha1)
    }
}

struct Md5sumCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "md5sum"
    static let overview = "Compute MD5 message digest"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await DigestCommandRunner.run(command: name, context: &context, files: options.files, digest: CommandHash.md5)
    }
}

