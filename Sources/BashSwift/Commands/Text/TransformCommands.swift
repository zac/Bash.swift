import ArgumentParser
import Foundation

struct SortCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Reverse the result")
        var r = false

        @Flag(name: .short, help: "Compare according to string numerical value")
        var n = false

        @Flag(name: .short, help: "Output only the first of an equal run")
        var u = false

        @Option(name: .short, help: "Sort via field key definition")
        var k: String?

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "sort"
    static let overview = "Sort lines of text"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let lines = inputs.contents.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

        let keyField = parseKeyField(options.k)
        let comparator: (String, String) -> Bool = { lhs, rhs in
            let lhsKey = keyForSort(line: lhs, field: keyField)
            let rhsKey = keyForSort(line: rhs, field: keyField)
            if options.n {
                let leftValue = Double(lhsKey) ?? 0
                let rightValue = Double(rhsKey) ?? 0
                if leftValue == rightValue {
                    return lhs < rhs
                }
                return leftValue < rightValue
            }
            if lhsKey == rhsKey {
                return lhs < rhs
            }
            return lhsKey < rhsKey
        }

        let sortedBase = lines.sorted(by: comparator)
        let sorted: [String]
        if options.r {
            sorted = Array(sortedBase.reversed())
        } else {
            sorted = sortedBase
        }

        var previous: String?
        for line in sorted {
            if options.u, previous == line {
                continue
            }
            context.writeStdout("\(line)\n")
            previous = line
        }
        return inputs.hadError ? 1 : 0
    }

    private static func parseKeyField(_ key: String?) -> Int? {
        guard let key, !key.isEmpty else {
            return nil
        }

        let fieldToken = key.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? key
        guard let value = Int(fieldToken), value > 0 else {
            return nil
        }
        return value
    }

    private static func keyForSort(line: String, field: Int?) -> String {
        guard let field else {
            return line
        }
        let pieces = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard field <= pieces.count else {
            return ""
        }
        return pieces[field - 1]
    }
}

struct UniqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Prefix lines by occurrence counts")
        var c = false

        @Flag(name: .short, help: "Only print duplicate lines")
        var d = false

        @Flag(name: .short, help: "Only print unique lines")
        var u = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "uniq"
    static let overview = "Report or omit repeated lines"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let lines = inputs.contents.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

        var previous: String?
        var count = 0

        func flushLine(_ line: String?, count: Int, context: inout CommandContext) {
            guard let line else { return }
            if options.d, count < 2 {
                return
            }
            if options.u, count != 1 {
                return
            }
            if options.c {
                context.writeStdout("\(count) \(line)\n")
            } else {
                context.writeStdout("\(line)\n")
            }
        }

        for line in lines {
            if line == previous {
                count += 1
            } else {
                flushLine(previous, count: count, context: &context)
                previous = line
                count = 1
            }
        }

        flushLine(previous, count: count, context: &context)
        return inputs.hadError ? 1 : 0
    }
}

struct CutCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .short, help: "Use DELIM instead of TAB")
        var d: String = "\t"

        @Option(name: .short, help: "Select only these fields")
        var f: String

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "cut"
    static let overview = "Remove sections from each line of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let fields = CommandFS.parseFieldList(options.f)
        guard !fields.isEmpty else {
            context.writeStderr("cut: invalid field list\n")
            return 1
        }

        let delimiter = options.d
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)

        for content in inputs.contents {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for line in lines {
                let parts = line.components(separatedBy: delimiter)
                var selected: [String] = []
                for (index, part) in parts.enumerated() where fields.contains(index + 1) {
                    selected.append(part)
                }
                context.writeStdout(selected.joined(separator: delimiter) + "\n")
            }
        }

        return inputs.hadError ? 1 : 0
    }
}

struct TrCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Characters to replace")
        var source: String

        @Argument(help: "Replacement characters")
        var destination: String
    }

    static let name = "tr"
    static let overview = "Translate or delete characters"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let input = CommandIO.decodeString(context.stdin)
        let source = Array(options.source)
        let destination = Array(options.destination)

        let translated = String(input.map { char in
            guard let index = source.firstIndex(of: char) else {
                return char
            }
            if destination.isEmpty {
                return char
            }
            let dest = destination[min(index, destination.count - 1)]
            return dest
        })

        context.writeStdout(translated)
        return 0
    }
}

