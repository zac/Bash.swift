import ArgumentParser
import Foundation
import BashCore

struct PlutilCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("p")], help: "Print a property list in a readable form")
        var printPropertyList = false

        @Flag(name: [.customLong("lint", withSingleDash: true)], help: "Check property list syntax")
        var lint = false

        @Option(name: [.customLong("convert", withSingleDash: true)], help: "Convert to json, xml1, or binary1")
        var convert: String?

        @Option(name: [.customShort("o")], help: "Write converted output to a file or '-'")
        var output: String?

        @Option(name: [.customLong("replace", withSingleDash: true)], help: "Replace a top-level key")
        var replaceKey: String?

        @Option(name: [.customLong("string", withSingleDash: true)], help: "Replacement string value")
        var stringValue: String?

        @Option(name: [.customLong("json", withSingleDash: true)], help: "Replacement JSON value")
        var jsonValue: String?

        @Argument(help: "Input files")
        var files: [String] = []
    }

    static let name = "plutil"
    static let overview = "Inspect and edit property list files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let selectedModeCount = [
            options.printPropertyList,
            options.lint,
            options.convert != nil,
            options.replaceKey != nil,
        ].filter { $0 }.count

        guard selectedModeCount == 1 else {
            context.writeStderr("plutil: specify exactly one operation\n")
            return 2
        }

        if options.printPropertyList {
            return await printPropertyLists(context: &context, files: options.files)
        }

        if options.lint {
            return await lint(context: &context, files: options.files)
        }

        if let format = options.convert {
            return await convert(context: &context, format: format, output: options.output, files: options.files)
        }

        if let key = options.replaceKey {
            return await replace(
                context: &context,
                key: key,
                stringValue: options.stringValue,
                jsonValue: options.jsonValue,
                files: options.files
            )
        }

        context.writeStderr("plutil: specify an operation\n")
        return 2
    }

    private static func printPropertyLists(context: inout CommandContext, files: [String]) async -> Int32 {
        guard !files.isEmpty else {
            context.writeStderr("plutil: -p requires a file\n")
            return 2
        }

        var failed = false
        for file in files {
            do {
                let document = try await readDocument(context: &context, file: file)
                context.writeStdout(renderPrintable(document.value))
                context.writeStdout("\n")
            } catch {
                context.writeStderr("plutil: \(file): \(CommandError.describe(error))\n")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func lint(context: inout CommandContext, files: [String]) async -> Int32 {
        guard !files.isEmpty else {
            context.writeStderr("plutil: -lint requires at least one file\n")
            return 2
        }

        var failed = false
        for file in files {
            do {
                _ = try await readDocument(context: &context, file: file)
                context.writeStdout("\(file): OK\n")
            } catch {
                context.writeStderr("\(file): \(CommandError.describe(error))\n")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func convert(
        context: inout CommandContext,
        format: String,
        output: String?,
        files: [String]
    ) async -> Int32 {
        guard !files.isEmpty else {
            context.writeStderr("plutil: -convert requires a file\n")
            return 2
        }

        if output != nil, files.count != 1 {
            context.writeStderr("plutil: -o can only be used with one input file\n")
            return 2
        }

        var failed = false
        for file in files {
            do {
                let document = try await readDocument(context: &context, file: file)
                let data = try serialize(document.value, as: format)
                if output == "-" {
                    context.stdout.append(data)
                    if format == "json", !data.hasSuffixByte(0x0A) {
                        context.writeStdout("\n")
                    }
                } else {
                    let destination = output ?? file
                    try await context.filesystem.writeFile(
                        path: context.resolvePath(destination),
                        data: data,
                        append: false
                    )
                }
            } catch {
                context.writeStderr("plutil: \(file): \(CommandError.describe(error))\n")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func replace(
        context: inout CommandContext,
        key: String,
        stringValue: String?,
        jsonValue: String?,
        files: [String]
    ) async -> Int32 {
        guard files.count == 1, let file = files.first else {
            context.writeStderr("plutil: -replace requires exactly one file\n")
            return 2
        }

        guard !key.isEmpty, !key.contains(".") else {
            context.writeStderr("plutil: -replace supports top-level keys only\n")
            return 2
        }

        let valueCount = [stringValue != nil, jsonValue != nil].filter { $0 }.count
        guard valueCount == 1 else {
            context.writeStderr("plutil: -replace requires exactly one value option (-string or -json)\n")
            return 2
        }

        do {
            let document = try await readDocument(context: &context, file: file)
            guard var dictionary = document.value as? [String: Any] else {
                context.writeStderr("plutil: \(file): top-level object is not a dictionary\n")
                return 1
            }

            if let stringValue {
                dictionary[key] = stringValue
            } else if let jsonValue {
                dictionary[key] = try parseJSONValue(jsonValue)
            }

            let data = try serializeForReplacement(dictionary, preserving: document.format)
            try await context.filesystem.writeFile(
                path: context.resolvePath(file),
                data: data,
                append: false
            )
            return 0
        } catch {
            context.writeStderr("plutil: \(file): \(CommandError.describe(error))\n")
            return 1
        }
    }

    private struct ParsedDocument {
        let value: Any
        let format: SourceFormat
    }

    private enum SourceFormat {
        case plist(PropertyListSerialization.PropertyListFormat)
        case json
    }

    private static func readDocument(context: inout CommandContext, file: String) async throws -> ParsedDocument {
        let data = if file == "-" {
            context.stdin
        } else {
            try await context.filesystem.readFile(path: context.resolvePath(file))
        }

        var plistFormat = PropertyListSerialization.PropertyListFormat.xml
        if let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &plistFormat
        ) {
            return ParsedDocument(value: plist, format: .plist(plistFormat))
        }

        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return ParsedDocument(value: json, format: .json)
        }

        throw ShellError.unsupported("invalid property list")
    }

    private static func parseJSONValue(_ source: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
        } catch {
            throw ShellError.unsupported("invalid JSON value")
        }
    }

    private static func serialize(_ value: Any, as format: String) throws -> Data {
        switch format {
        case "json":
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted]
            )
        case "xml1":
            return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        case "binary1":
            return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        default:
            throw ShellError.unsupported("unsupported conversion format '\(format)'")
        }
    }

    private static func serializeForReplacement(_ value: Any, preserving format: SourceFormat) throws -> Data {
        switch format {
        case .json:
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted]
            )
        case let .plist(plistFormat):
            let writeFormat: PropertyListSerialization.PropertyListFormat
            switch plistFormat {
            case .binary:
                writeFormat = .binary
            default:
                writeFormat = .xml
            }
            return try PropertyListSerialization.data(fromPropertyList: value, format: writeFormat, options: 0)
        }
    }

    private static func renderPrintable(_ value: Any, indent: Int = 0) -> String {
        let padding = String(repeating: "  ", count: indent)
        let childPadding = String(repeating: "  ", count: indent + 1)

        if let dictionary = value as? [String: Any] {
            guard !dictionary.isEmpty else { return "{" + "\n" + padding + "}" }
            var lines = ["{"]
            for key in dictionary.keys.sorted() {
                let rendered = renderPrintable(dictionary[key] ?? NSNull(), indent: indent + 1)
                lines.append("\(childPadding)\"\(escapeString(key))\" => \(rendered)")
            }
            lines.append("\(padding)}")
            return lines.joined(separator: "\n")
        }

        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[" + "\n" + padding + "]" }
            var lines = ["["]
            for (index, item) in array.enumerated() {
                let rendered = renderPrintable(item, indent: indent + 1)
                lines.append("\(childPadding)\(index) => \(rendered)")
            }
            lines.append("\(padding)]")
            return lines.joined(separator: "\n")
        }

        if let string = value as? String {
            return "\"\(escapeString(string))\""
        }

        if let date = value as? Date {
            return "\"\(ISO8601DateFormatter().string(from: date))\""
        }

        if let data = value as? Data {
            return "\"\(data.base64EncodedString())\""
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "1" : "0"
            }
            return number.stringValue
        }

        if value is NSNull {
            return "null"
        }

        return "\"\(escapeString(String(describing: value)))\""
    }

    private static func escapeString(_ string: String) -> String {
        var output = ""
        for character in string {
            switch character {
            case "\\":
                output += "\\\\"
            case "\"":
                output += "\\\""
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                output.append(character)
            }
        }
        return output
    }
}

private extension Data {
    func hasSuffixByte(_ byte: UInt8) -> Bool {
        last == byte
    }
}
