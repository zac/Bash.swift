import ArgumentParser
import Foundation

struct JqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Output raw strings")
        var r = false

        @Flag(name: [.short, .customLong("compact-output")], help: "Compact JSON output")
        var c = false

        @Flag(name: .short, help: "Set exit status based on output")
        var e = false

        @Flag(name: [.short, .customLong("slurp")], help: "Read all input values into an array")
        var s = false

        @Flag(name: [.short, .customLong("null-input")], help: "Do not read input")
        var n = false

        @Flag(name: [.short, .customLong("join-output")], help: "Suppress newline between outputs")
        var j = false

        @Flag(name: [.short, .customLong("sort-keys")], help: "Sort object keys in output")
        var S = false

        @Argument(help: "Query expression")
        var query: String

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "jq"
    static let overview = "Process JSON data with a simple query language"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await StructuredDataQueryRunner.run(
            context: &context,
            commandName: name,
            query: options.query,
            files: options.files,
            parseDocument: StructuredDataParsers.parseJSONDocument,
            options: StructuredDataQueryRunner.Options(
                rawOutput: options.r,
                compactOutput: options.c,
                sortKeys: options.S,
                joinOutput: options.j,
                exitStatus: options.e,
                slurp: options.s,
                nullInput: options.n
            )
        )
    }
}

struct YqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Output raw strings")
        var r = false

        @Flag(name: [.short, .customLong("compact-output")], help: "Compact JSON output")
        var c = false

        @Flag(name: .short, help: "Set exit status based on output")
        var e = false

        @Flag(name: [.short, .customLong("slurp")], help: "Read all input values into an array")
        var s = false

        @Flag(name: [.short, .customLong("null-input")], help: "Do not read input")
        var n = false

        @Flag(name: [.short, .customLong("join-output")], help: "Suppress newline between outputs")
        var j = false

        @Flag(name: [.short, .customLong("sort-keys")], help: "Sort object keys in output")
        var S = false

        @Argument(help: "Query expression")
        var query: String

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "yq"
    static let overview = "Process YAML/JSON data with a simple query language"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await StructuredDataQueryRunner.run(
            context: &context,
            commandName: name,
            query: options.query,
            files: options.files,
            parseDocument: StructuredDataParsers.parseYQDocument,
            options: StructuredDataQueryRunner.Options(
                rawOutput: options.r,
                compactOutput: options.c,
                sortKeys: options.S,
                joinOutput: options.j,
                exitStatus: options.e,
                slurp: options.s,
                nullInput: options.n
            )
        )
    }
}

struct XanCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Subcommand and arguments")
        var values: [String] = []
    }

    static let name = "xan"
    static let overview = "CSV toolkit (count, headers, select, filter)"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard let subcommand = options.values.first else {
            context.writeStderr("xan: missing subcommand (count|headers|select|filter)\n")
            return 2
        }

        let args = Array(options.values.dropFirst())
        switch subcommand {
        case "count":
            return await runCount(context: &context, args: args)
        case "headers":
            return await runHeaders(context: &context, args: args)
        case "select":
            return await runSelect(context: &context, args: args)
        case "filter":
            return await runFilter(context: &context, args: args)
        default:
            context.writeStderr("xan: unsupported subcommand: \(subcommand)\n")
            return 2
        }
    }

    private static func runCount(context: inout CommandContext, args: [String]) async -> Int32 {
        let input = await readInput(context: &context, args: args)
        guard let input else { return 1 }

        do {
            let table = try CSVCodec.parse(input.text)
            let count = max(0, table.rows.count - 1)
            context.writeStdout("\(count)\n")
            return 0
        } catch {
            context.writeStderr("xan: \(error)\n")
            return 1
        }
    }

    private static func runHeaders(context: inout CommandContext, args: [String]) async -> Int32 {
        let input = await readInput(context: &context, args: args)
        guard let input else { return 1 }

        do {
            let table = try CSVCodec.parse(input.text)
            guard let header = table.rows.first else { return 0 }
            for (index, value) in header.enumerated() {
                context.writeStdout("\(index + 1),\(value)\n")
            }
            return 0
        } catch {
            context.writeStderr("xan: \(error)\n")
            return 1
        }
    }

    private static func runSelect(context: inout CommandContext, args: [String]) async -> Int32 {
        guard !args.isEmpty else {
            context.writeStderr("xan: select requires <columns>\n")
            return 2
        }

        let selector = args[0]
        let input = await readInput(context: &context, args: Array(args.dropFirst()))
        guard let input else { return 1 }

        do {
            let table = try CSVCodec.parse(input.text)
            guard let header = table.rows.first else {
                return 0
            }

            let indices = try resolveColumnIndices(selector: selector, header: header)
            var outputRows: [[String]] = []
            for row in table.rows {
                outputRows.append(indices.map { column in
                    column < row.count ? row[column] : ""
                })
            }

            context.writeStdout(CSVCodec.render(outputRows))
            return 0
        } catch {
            context.writeStderr("xan: \(error)\n")
            return 1
        }
    }

    private static func runFilter(context: inout CommandContext, args: [String]) async -> Int32 {
        guard args.count >= 2 else {
            context.writeStderr("xan: filter requires <column> <pattern>\n")
            return 2
        }

        let selector = args[0]
        let pattern = args[1]
        let input = await readInput(context: &context, args: Array(args.dropFirst(2)))
        guard let input else { return 1 }

        do {
            let table = try CSVCodec.parse(input.text)
            guard let header = table.rows.first else {
                return 0
            }

            let index = try resolveSingleColumnIndex(selector: selector, header: header)
            var outputRows: [[String]] = [header]

            for row in table.rows.dropFirst() {
                let value = index < row.count ? row[index] : ""
                if value.contains(pattern) {
                    outputRows.append(row)
                }
            }

            context.writeStdout(CSVCodec.render(outputRows))
            return 0
        } catch {
            context.writeStderr("xan: \(error)\n")
            return 1
        }
    }

    private static func readInput(
        context: inout CommandContext,
        args: [String]
    ) async -> (text: String, label: String)? {
        if args.count > 1 {
            context.writeStderr("xan: expected at most one file operand\n")
            return nil
        }

        if let file = args.first {
            do {
                let data = try await context.filesystem.readFile(path: context.resolvePath(file))
                return (CommandIO.decodeString(data), file)
            } catch {
                context.writeStderr("xan: \(file): \(error)\n")
                return nil
            }
        }

        return (CommandIO.decodeString(context.stdin), "-")
    }

    private static func resolveColumnIndices(selector: String, header: [String]) throws -> [Int] {
        var indices: [Int] = []
        var seen = Set<Int>()

        for token in selector.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            let index: Int
            if let numeric = Int(token), numeric > 0 {
                index = numeric - 1
                guard index < header.count else {
                    throw ShellError.unsupported("column out of range: \(token)")
                }
            } else if let found = header.firstIndex(of: token) {
                index = found
            } else {
                throw ShellError.unsupported("unknown column: \(token)")
            }

            if seen.insert(index).inserted {
                indices.append(index)
            }
        }

        if indices.isEmpty {
            throw ShellError.unsupported("no columns selected")
        }

        return indices
    }

    private static func resolveSingleColumnIndex(selector: String, header: [String]) throws -> Int {
        let indices = try resolveColumnIndices(selector: selector, header: header)
        guard indices.count == 1 else {
            throw ShellError.unsupported("filter expects exactly one column")
        }
        return indices[0]
    }
}

private enum StructuredDataQueryRunner {
    typealias DocumentParser = (String) throws -> Any

    struct Options {
        let rawOutput: Bool
        let compactOutput: Bool
        let sortKeys: Bool
        let joinOutput: Bool
        let exitStatus: Bool
        let slurp: Bool
        let nullInput: Bool
    }

    static func run(
        context: inout CommandContext,
        commandName: String,
        query: String,
        files: [String],
        parseDocument: DocumentParser,
        options: Options
    ) async -> Int32 {
        let program: StructuredQueryProgram
        do {
            program = try StructuredQueryProgram.parse(query)
        } catch {
            context.writeStderr("\(commandName): \(error)\n")
            return 2
        }

        var inputs: [String] = []
        var hadIOError = false
        if !options.nullInput {
            let read = await CommandFS.readInputs(paths: files, context: &context)
            inputs = read.contents
            hadIOError = read.hadError
        }

        var documents: [Any] = []
        var hadRuntimeError = false

        for content in inputs {
            do {
                documents.append(try parseDocument(content))
            } catch {
                context.writeStderr("\(commandName): \(error)\n")
                hadRuntimeError = true
            }
        }

        if options.nullInput {
            documents = [NSNull()]
        } else if options.slurp {
            documents = [documents]
        }

        var lastOutput: Any = NSNull()
        var emittedValues = 0
        let renderOptions = StructuredQueryRenderOptions(
            rawOutput: options.rawOutput,
            compactOutput: options.compactOutput,
            sortKeys: options.sortKeys
        )

        for document in documents {
            do {
                let values = try program.evaluate(input: document)
                for value in values {
                    let rendered = try StructuredQueryRenderer.render(value, options: renderOptions)
                    context.writeStdout(rendered)
                    if !options.joinOutput {
                        context.writeStdout("\n")
                    }
                    lastOutput = value
                    emittedValues += 1
                }
            } catch {
                context.writeStderr("\(commandName): \(error)\n")
                hadRuntimeError = true
            }
        }

        if hadIOError || hadRuntimeError {
            return 1
        }

        if options.exitStatus {
            if emittedValues == 0 {
                return 4
            }
            return structuredQueryIsTruthy(lastOutput) ? 0 : 1
        }

        return 0
    }
}

private func structuredQueryIsTruthy(_ value: Any) -> Bool {
    if (value as? NSNull) != nil {
        return false
    }
    if let boolean = value as? Bool {
        return boolean
    }
    return true
}

private enum StructuredDataParsers {
    static func parseJSONDocument(_ source: String) throws -> Any {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShellError.unsupported("empty input")
        }

        do {
            return try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            throw ShellError.unsupported("invalid JSON input")
        }
    }

    static func parseYQDocument(_ source: String) throws -> Any {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShellError.unsupported("empty input")
        }

        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            return json
        }

        return try SimpleYAMLParser.parse(trimmed)
    }
}

private enum StructuredDataQuery {
    enum Step {
        case key(String)
        case index(Int)
        case iterate
    }

    static func parse(_ query: String) throws -> [Step] {
        guard query.hasPrefix(".") else {
            throw ShellError.unsupported("query must start with '.'")
        }
        if query == "." {
            return []
        }

        var steps: [Step] = []
        var index = query.index(after: query.startIndex)

        while index < query.endIndex {
            if query[index] == "." {
                index = query.index(after: index)
                if index == query.endIndex {
                    break
                }
            }

            if query[index] == "[" {
                let bracket = try parseBracket(query, index: &index)
                steps.append(bracket)
                continue
            }

            let keyStart = index
            while index < query.endIndex, query[index] != ".", query[index] != "[" {
                index = query.index(after: index)
            }

            let key = String(query[keyStart..<index])
            guard !key.isEmpty else {
                throw ShellError.unsupported("invalid query")
            }
            steps.append(.key(key))

            while index < query.endIndex, query[index] == "[" {
                let bracket = try parseBracket(query, index: &index)
                steps.append(bracket)
            }
        }

        return steps
    }

    static func evaluate(_ root: Any, steps: [Step]) -> [Any] {
        var values: [Any] = [root]
        for step in steps {
            switch step {
            case let .key(key):
                values = values.map { value in
                    guard let object = value as? [String: Any] else { return NSNull() }
                    return object[key] ?? NSNull()
                }
            case let .index(index):
                values = values.map { value in
                    guard let array = value as? [Any], index >= 0, index < array.count else { return NSNull() }
                    return array[index]
                }
            case .iterate:
                var expanded: [Any] = []
                for value in values {
                    if let array = value as? [Any] {
                        expanded.append(contentsOf: array)
                    } else if let object = value as? [String: Any] {
                        for key in object.keys.sorted() {
                            expanded.append(object[key] ?? NSNull())
                        }
                    }
                }
                values = expanded
            }
        }

        return values
    }

    private static func parseBracket(_ query: String, index: inout String.Index) throws -> Step {
        guard query[index] == "[" else {
            throw ShellError.unsupported("invalid query")
        }

        index = query.index(after: index)
        let contentStart = index
        while index < query.endIndex, query[index] != "]" {
            index = query.index(after: index)
        }
        guard index < query.endIndex else {
            throw ShellError.unsupported("unterminated [] in query")
        }

        let raw = String(query[contentStart..<index]).trimmingCharacters(in: .whitespaces)
        index = query.index(after: index)

        if raw.isEmpty {
            return .iterate
        }
        if let numeric = Int(raw) {
            return .index(numeric)
        }
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            let start = raw.index(after: raw.startIndex)
            let end = raw.index(before: raw.endIndex)
            return .key(String(raw[start..<end]))
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            let start = raw.index(after: raw.startIndex)
            let end = raw.index(before: raw.endIndex)
            return .key(String(raw[start..<end]))
        }

        throw ShellError.unsupported("unsupported [] selector: \(raw)")
    }
}

private enum StructuredDataRender {
    static func render(_ value: Any, rawStrings: Bool, compactJSON: Bool) throws -> String {
        if rawStrings, let string = value as? String {
            return string
        }

        do {
            var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
            if !compactJSON {
                options.insert(.prettyPrinted)
                options.insert(.sortedKeys)
            }

            let data = try JSONSerialization.data(withJSONObject: value, options: options)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ShellError.unsupported("unable to render query result")
        }
    }
}

private enum SimpleYAMLParser {
    private struct Line {
        let indent: Int
        let content: String
    }

    static func parse(_ source: String) throws -> Any {
        let lines = tokenize(source)
        guard !lines.isEmpty else {
            return NSNull()
        }

        var index = 0
        return try parseNode(lines: lines, index: &index, expectedIndent: lines[0].indent)
    }

    private static func tokenize(_ source: String) -> [Line] {
        var output: [Line] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let comment = line.firstIndex(of: "#"), line[..<comment].trimmingCharacters(in: .whitespaces).isEmpty == false {
                // Keep inline '#' for now if value has text before it.
            } else if let comment = line.firstIndex(of: "#") {
                line = String(line[..<comment])
            }

            line = line.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            let indent = line.prefix { $0 == " " }.count
            output.append(Line(indent: indent, content: trimmed))
        }
        return output
    }

    private static func parseNode(lines: [Line], index: inout Int, expectedIndent: Int) throws -> Any {
        guard index < lines.count else {
            return NSNull()
        }

        if lines[index].content.hasPrefix("- "), lines[index].indent == expectedIndent {
            return try parseSequence(lines: lines, index: &index, expectedIndent: expectedIndent)
        }
        return try parseMapping(lines: lines, index: &index, expectedIndent: expectedIndent)
    }

    private static func parseMapping(lines: [Line], index: inout Int, expectedIndent: Int) throws -> [String: Any] {
        var map: [String: Any] = [:]

        while index < lines.count {
            let line = lines[index]
            if line.indent < expectedIndent {
                break
            }
            if line.indent > expectedIndent {
                throw ShellError.unsupported("invalid YAML indentation")
            }
            if line.content.hasPrefix("- ") {
                break
            }

            guard let colon = line.content.firstIndex(of: ":") else {
                throw ShellError.unsupported("invalid YAML mapping entry")
            }

            let key = line.content[..<colon].trimmingCharacters(in: .whitespaces)
            let remainder = line.content[line.content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ShellError.unsupported("invalid YAML key")
            }

            index += 1
            if remainder.isEmpty {
                if index < lines.count, lines[index].indent > expectedIndent {
                    map[key] = try parseNode(lines: lines, index: &index, expectedIndent: lines[index].indent)
                } else {
                    map[key] = NSNull()
                }
            } else {
                map[key] = parseScalar(remainder)
            }
        }

        return map
    }

    private static func parseSequence(lines: [Line], index: inout Int, expectedIndent: Int) throws -> [Any] {
        var array: [Any] = []

        while index < lines.count {
            let line = lines[index]
            if line.indent < expectedIndent {
                break
            }
            guard line.indent == expectedIndent, line.content.hasPrefix("- ") else {
                break
            }

            let remainder = String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1

            if remainder.isEmpty {
                if index < lines.count, lines[index].indent > expectedIndent {
                    array.append(try parseNode(lines: lines, index: &index, expectedIndent: lines[index].indent))
                } else {
                    array.append(NSNull())
                }
                continue
            }

            if let colon = remainder.firstIndex(of: ":"), !remainder.hasPrefix("\""), !remainder.hasPrefix("'") {
                let key = remainder[..<colon].trimmingCharacters(in: .whitespaces)
                let valueText = remainder[remainder.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    var object: [String: Any] = [:]
                    if valueText.isEmpty {
                        if index < lines.count, lines[index].indent > expectedIndent {
                            object[key] = try parseNode(lines: lines, index: &index, expectedIndent: lines[index].indent)
                        } else {
                            object[key] = NSNull()
                        }
                    } else {
                        object[key] = parseScalar(valueText)
                    }

                    if index < lines.count, lines[index].indent > expectedIndent {
                        let nested = try parseNode(lines: lines, index: &index, expectedIndent: lines[index].indent)
                        if let nestedMap = nested as? [String: Any] {
                            for (nestedKey, nestedValue) in nestedMap {
                                object[nestedKey] = nestedValue
                            }
                        }
                    }

                    array.append(object)
                    continue
                }
            }

            array.append(parseScalar(remainder))
        }

        return array
    }

    private static func parseScalar<S: StringProtocol>(_ token: S) -> Any {
        let value = String(token)

        if value == "null" || value == "~" {
            return NSNull()
        }
        if value == "true" {
            return true
        }
        if value == "false" {
            return false
        }
        if let intValue = Int(value) {
            return intValue
        }
        if let doubleValue = Double(value) {
            return doubleValue
        }

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            let start = value.index(after: value.startIndex)
            let end = value.index(before: value.endIndex)
            return unescapeDoubleQuoted(String(value[start..<end]))
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            let start = value.index(after: value.startIndex)
            let end = value.index(before: value.endIndex)
            return String(value[start..<end])
        }

        return value
    }

    private static func unescapeDoubleQuoted(_ input: String) -> String {
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            guard character == "\\" else {
                output.append(character)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append("\\")
                break
            }

            switch input[next] {
            case "n":
                output.append("\n")
            case "t":
                output.append("\t")
            case "r":
                output.append("\r")
            case "\\":
                output.append("\\")
            case "\"":
                output.append("\"")
            default:
                output.append(input[next])
            }

            index = input.index(after: next)
        }

        return output
    }
}

private enum CSVCodec {
    struct Table {
        let rows: [[String]]
    }

    static func parse(_ input: String) throws -> Table {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]

            if inQuotes {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        inQuotes = false
                        index = next
                    }
                    continue
                }

                field.append(character)
                index = input.index(after: index)
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
                index = input.index(after: index)
            case ",":
                row.append(field)
                field = ""
                index = input.index(after: index)
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                index = input.index(after: index)
            case "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                index = input.index(after: index)
                if index < input.endIndex, input[index] == "\n" {
                    index = input.index(after: index)
                }
            default:
                field.append(character)
                index = input.index(after: index)
            }
        }

        if inQuotes {
            throw ShellError.unsupported("unterminated quoted CSV field")
        }

        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return Table(rows: rows)
    }

    static func render(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map(escapeField).joined(separator: ",")
        }
        .joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    private static func escapeField(_ field: String) -> String {
        if field.contains(",") || field.contains("\n") || field.contains("\r") || field.contains("\"") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}
