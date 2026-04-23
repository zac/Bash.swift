import ArgumentParser
import Foundation
import BashCore

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

struct XxdCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("p"), .long], help: "Output a plain continuous hex dump")
        var plain = false

        @Flag(name: [.short, .long], help: "Use uppercase hex letters")
        var upper = false

        @Option(name: [.customShort("c"), .long], help: "Bytes per output line")
        var columns: Int?

        @Option(name: [.customShort("g"), .long], help: "Group bytes in the hex column")
        var groupSize: Int?

        @Option(name: [.customShort("l"), .long], help: "Stop after this many bytes")
        var length: Int?

        @Option(name: [.customShort("s"), .long], help: "Start at this byte offset")
        var seek: Int = 0

        @Argument(help: "Optional input file ('-' for stdin)")
        var input: String?

        @Argument(help: "Optional output file")
        var output: String?
    }

    static let name = "xxd"
    static let overview = "Create a hex dump from files or stdin"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let columns = options.columns ?? (options.plain ? 30 : 16)
        guard columns > 0 else {
            context.writeStderr("xxd: columns must be > 0\n")
            return 1
        }

        let groupSize = options.groupSize ?? (options.plain ? 0 : 2)
        guard groupSize >= 0 else {
            context.writeStderr("xxd: group size must be >= 0\n")
            return 1
        }

        if let length = options.length, length < 0 {
            context.writeStderr("xxd: length must be >= 0\n")
            return 1
        }

        guard options.seek >= 0 else {
            context.writeStderr("xxd: seek must be >= 0\n")
            return 1
        }

        let inputData: Data
        do {
            inputData = try await readInputData(context: &context, input: options.input)
        } catch {
            let label = options.input ?? "-"
            context.writeStderr("xxd: \(label): \(error)\n")
            return 1
        }

        let start = min(options.seek, inputData.count)
        let requestedLength = options.length ?? (inputData.count - start)
        let end = min(inputData.count, start + requestedLength)
        let data = inputData.subdata(in: start..<end)

        let rendered = if options.plain {
            renderPlain(data, columns: columns, uppercase: options.upper)
        } else {
            renderCanonical(
                data,
                columns: columns,
                groupSize: groupSize,
                startOffset: start,
                uppercase: options.upper
            )
        }

        if let output = options.output, output != "-" {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(output),
                    data: rendered,
                    append: false
                )
            } catch {
                context.writeStderr("xxd: \(output): \(error)\n")
                return 1
            }
        } else {
            context.stdout.append(rendered)
        }

        return 0
    }

    private static func readInputData(
        context: inout CommandContext,
        input: String?
    ) async throws -> Data {
        guard let input, input != "-" else {
            return context.stdin
        }
        return try await context.filesystem.readFile(path: context.resolvePath(input))
    }

    private static func renderPlain(
        _ data: Data,
        columns: Int,
        uppercase: Bool
    ) -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        var lines: [String] = []
        var offset = 0
        while offset < data.count {
            let upperBound = min(data.count, offset + columns)
            let chunk = data[offset..<upperBound]
            lines.append(chunk.map { hexByte($0, uppercase: uppercase) }.joined())
            offset = upperBound
        }

        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func renderCanonical(
        _ data: Data,
        columns: Int,
        groupSize: Int,
        startOffset: Int,
        uppercase: Bool
    ) -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        let fullHexWidth = hexAreaWidth(columns: columns, groupSize: groupSize)
        var lines: [String] = []
        var offset = 0

        while offset < data.count {
            let upperBound = min(data.count, offset + columns)
            let chunk = data[offset..<upperBound]
            let hex = renderHexColumn(chunk, groupSize: groupSize, uppercase: uppercase)
            let padding = String(repeating: " ", count: max(0, fullHexWidth - hex.count))
            let ascii = chunk.map(renderASCII).joined()
            lines.append(String(format: "%08x: ", startOffset + offset) + hex + padding + "  " + ascii)
            offset = upperBound
        }

        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func renderHexColumn(
        _ bytes: Data.SubSequence,
        groupSize: Int,
        uppercase: Bool
    ) -> String {
        var result = ""
        for (index, byte) in bytes.enumerated() {
            if groupSize > 0, index > 0, index.isMultiple(of: groupSize) {
                result.append(" ")
            }
            result.append(hexByte(byte, uppercase: uppercase))
        }
        return result
    }

    private static func hexAreaWidth(columns: Int, groupSize: Int) -> Int {
        guard groupSize > 0 else {
            return columns * 2
        }
        return (columns * 2) + ((max(columns - 1, 0)) / groupSize)
    }

    private static func hexByte(_ byte: UInt8, uppercase: Bool) -> String {
        String(format: uppercase ? "%02X" : "%02x", byte)
    }

    private static func renderASCII(_ byte: UInt8) -> String {
        guard (0x20...0x7E).contains(byte) else {
            return "."
        }
        return String(UnicodeScalar(byte))
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
