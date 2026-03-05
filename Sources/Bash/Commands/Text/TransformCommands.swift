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

        @Flag(name: .short, help: "Fold lower case to upper case characters")
        var f = false

        @Flag(name: .short, help: "Check whether input is sorted")
        var c = false

        @Option(name: .short, help: "Sort via field key definition")
        var k: String?

        @Option(name: .short, help: "Write result to FILE instead of standard output")
        var o: String?

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "sort"
    static let overview = "Sort lines of text"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.c, options.o != nil {
            context.writeStderr("sort: cannot combine -c and -o\n")
            return 2
        }

        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let lines = inputs.contents.flatMap { CommandIO.splitLines($0) }

        let keyField = parseKeyField(options.k)
        let comparator: (String, String) -> Int = { lhs, rhs in
            compareLines(lhs: lhs, rhs: rhs, options: options, keyField: keyField)
        }

        if options.c {
            for index in 1..<lines.count {
                if comparator(lines[index - 1], lines[index]) > 0 {
                    context.writeStderr("sort: input is not sorted\n")
                    return 1
                }
            }
            return inputs.hadError ? 1 : 0
        }

        let sortedBase = lines.sorted { comparator($0, $1) < 0 }
        let sorted: [String]
        if options.r {
            sorted = Array(sortedBase.reversed())
        } else {
            sorted = sortedBase
        }

        var output: [String] = []
        if options.u {
            var previous: String?
            for line in sorted {
                if let previous, comparator(previous, line) == 0 {
                    continue
                }
                output.append(line)
                previous = line
            }
        } else {
            output = sorted
        }

        let rendered = output.map { "\($0)\n" }.joined()
        if let outputFile = options.o {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(outputFile),
                    data: Data(rendered.utf8),
                    append: false
                )
            } catch {
                context.writeStderr("sort: \(outputFile): \(error)\n")
                return 1
            }
        } else {
            context.writeStdout(rendered)
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

    private static func compareLines(lhs: String, rhs: String, options: Options, keyField: Int?) -> Int {
        let lhsRawKey = keyForSort(line: lhs, field: keyField)
        let rhsRawKey = keyForSort(line: rhs, field: keyField)
        let lhsKey = options.f ? lhsRawKey.lowercased() : lhsRawKey
        let rhsKey = options.f ? rhsRawKey.lowercased() : rhsRawKey

        if options.n {
            let leftValue = Double(lhsKey) ?? 0
            let rightValue = Double(rhsKey) ?? 0
            if leftValue < rightValue { return -1 }
            if leftValue > rightValue { return 1 }
        } else {
            if lhsKey < rhsKey { return -1 }
            if lhsKey > rhsKey { return 1 }
        }

        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
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

        @Flag(name: .short, help: "Ignore case when comparing")
        var i = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "uniq"
    static let overview = "Report or omit repeated lines"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.files.count > 2 {
            context.writeStderr("uniq: extra operand '\(options.files[2])'\n")
            return 1
        }

        let inputPath = options.files.first
        let outputPath = options.files.count == 2 ? options.files[1] : nil
        let readPaths = inputPath.map { [$0] } ?? []
        let inputs = await CommandFS.readInputs(paths: readPaths, context: &context)
        let lines = inputs.contents.flatMap { CommandIO.splitLines($0) }

        var previous: String?
        var previousKey: String?
        var count = 0
        var rendered: [String] = []

        func flushLine(_ line: String?, count: Int) {
            guard let line else { return }
            if options.d, count < 2 {
                return
            }
            if options.u, count != 1 {
                return
            }
            if options.c {
                rendered.append("\(count) \(line)")
            } else {
                rendered.append(line)
            }
        }

        for line in lines {
            let key = options.i ? line.lowercased() : line
            if key == previousKey {
                count += 1
            } else {
                flushLine(previous, count: count)
                previous = line
                previousKey = key
                count = 1
            }
        }

        flushLine(previous, count: count)

        let outputData = Data(rendered.map { "\($0)\n" }.joined().utf8)
        if let outputPath {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(outputPath),
                    data: outputData,
                    append: false
                )
            } catch {
                context.writeStderr("uniq: \(outputPath): \(error)\n")
                return 1
            }
        } else {
            context.stdout.append(outputData)
        }

        return inputs.hadError ? 1 : 0
    }
}

struct CutCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .short, help: "Use DELIM instead of TAB")
        var d: String = "\t"

        @Option(name: .short, help: "Select only these fields")
        var f: String?

        @Option(name: .short, help: "Select only these characters")
        var c: String?

        @Flag(name: .short, help: "Do not print lines with no delimiter characters")
        var s = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "cut"
    static let overview = "Remove sections from each line of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        enum Mode {
            case field([SelectionRange])
            case character([SelectionRange])
        }

        let mode: Mode
        switch (options.f, options.c) {
        case (.none, .none):
            context.writeStderr("cut: one of -f or -c must be specified\n")
            return 1
        case (.some, .some):
            context.writeStderr("cut: options -f and -c are mutually exclusive\n")
            return 1
        case let (.some(fieldSpec), .none):
            guard let ranges = parseSelectionRanges(fieldSpec), !ranges.isEmpty else {
                context.writeStderr("cut: invalid field list\n")
                return 1
            }
            mode = .field(ranges)
        case let (.none, .some(charSpec)):
            guard let ranges = parseSelectionRanges(charSpec), !ranges.isEmpty else {
                context.writeStderr("cut: invalid character list\n")
                return 1
            }
            mode = .character(ranges)
        }

        if case .field = mode, options.d.isEmpty {
            context.writeStderr("cut: delimiter must not be empty\n")
            return 1
        }

        let delimiter = options.d
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)

        for content in inputs.contents {
            let lines = CommandIO.splitLines(content)
            for line in lines {
                switch mode {
                case .field(let ranges):
                    if !line.contains(delimiter) {
                        if !options.s {
                            context.writeStdout("\(line)\n")
                        }
                        continue
                    }

                    let parts = line.components(separatedBy: delimiter)
                    let selectedIndexes = selectIndexes(totalCount: parts.count, ranges: ranges)
                    let selected = selectedIndexes.map { parts[$0 - 1] }
                    context.writeStdout(selected.joined(separator: delimiter) + "\n")

                case .character(let ranges):
                    let characters = Array(line)
                    let selectedIndexes = selectIndexes(totalCount: characters.count, ranges: ranges)
                    let selected = selectedIndexes.map { characters[$0 - 1] }
                    context.writeStdout(String(selected) + "\n")
                }
            }
        }

        return inputs.hadError ? 1 : 0
    }
}

struct TrCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Delete characters in SET1")
        var d = false

        @Flag(name: .short, help: "Squeeze repeated characters listed in the last specified SET")
        var s = false

        @Flag(name: .short, help: "Use the complement of SET1")
        var c = false

        @Argument(help: "SET1")
        var source: String

        @Argument(help: "SET2")
        var destination: String?
    }

    static let name = "tr"
    static let overview = "Translate or delete characters"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let input = CommandIO.decodeString(context.stdin)

        if let destination = options.destination {
            if options.source == "[:lower:]" && destination == "[:upper:]" {
                context.writeStdout(input.uppercased())
                return 0
            }
            if options.source == "[:upper:]" && destination == "[:lower:]" {
                context.writeStdout(input.lowercased())
                return 0
            }
        }

        let inputCharacters = Array(input)
        let sourceCharacters = expandCharacterSet(options.source)
        let sourceSet = Set(sourceCharacters)

        let effectiveSourceCharacters: [Character]
        if options.c {
            var seen: Set<Character> = []
            var complement: [Character] = []
            for character in inputCharacters where !sourceSet.contains(character) {
                if seen.insert(character).inserted {
                    complement.append(character)
                }
            }
            effectiveSourceCharacters = complement
        } else {
            effectiveSourceCharacters = sourceCharacters
        }
        let effectiveSourceSet = Set(effectiveSourceCharacters)

        if options.d {
            var transformed = inputCharacters.filter { !effectiveSourceSet.contains($0) }
            if options.s {
                let squeezeSource = options.destination.map(expandCharacterSet) ?? effectiveSourceCharacters
                transformed = squeezeCharacters(transformed, set: Set(squeezeSource))
            }
            context.writeStdout(String(transformed))
            return 0
        }

        if let destination = options.destination {
            let destinationCharacters = expandCharacterSet(destination)
            guard !destinationCharacters.isEmpty else {
                context.writeStderr("tr: replacement set must not be empty\n")
                return 1
            }

            let translationMap = buildTranslationMap(
                source: effectiveSourceCharacters,
                destination: destinationCharacters
            )
            var transformed = inputCharacters.map { character in
                translationMap[character] ?? character
            }
            if options.s {
                transformed = squeezeCharacters(transformed, set: Set(destinationCharacters))
            }
            context.writeStdout(String(transformed))
            return 0
        }

        guard options.s else {
            context.writeStderr("tr: missing replacement string\n")
            return 1
        }

        let squeezed = squeezeCharacters(inputCharacters, set: effectiveSourceSet)
        context.writeStdout(String(squeezed))
        return 0
    }

    private static func buildTranslationMap(
        source: [Character],
        destination: [Character]
    ) -> [Character: Character] {
        guard let finalDestination = destination.last else {
            return [:]
        }

        var map: [Character: Character] = [:]
        for (index, character) in source.enumerated() {
            map[character] = destination[index < destination.count ? index : destination.count - 1]
        }
        if map.isEmpty {
            _ = finalDestination
        }
        return map
    }

    private static func squeezeCharacters(_ characters: [Character], set: Set<Character>) -> [Character] {
        guard !set.isEmpty else {
            return characters
        }

        var output: [Character] = []
        var previous: Character?
        for character in characters {
            if previous == character, set.contains(character) {
                continue
            }
            output.append(character)
            previous = character
        }
        return output
    }

    private static func expandCharacterSet(_ raw: String) -> [Character] {
        if raw.hasPrefix("[:"), raw.hasSuffix(":]"), raw.count > 4 {
            let start = raw.index(raw.startIndex, offsetBy: 2)
            let end = raw.index(raw.endIndex, offsetBy: -2)
            let className = String(raw[start..<end])
            if let classCharacters = posixClassCharacters(named: className) {
                return classCharacters
            }
        }

        let unescaped = decodeEscapes(raw)
        guard unescaped.count >= 3 else {
            return unescaped
        }

        var output: [Character] = []
        var index = 0
        while index < unescaped.count {
            var consumedPOSIXClass = false
            if index + 3 < unescaped.count,
               unescaped[index] == "[",
               unescaped[index + 1] == ":" {
                var cursor = index + 2
                while cursor + 1 < unescaped.count {
                    if unescaped[cursor] == ":", unescaped[cursor + 1] == "]" {
                        let className = String(unescaped[(index + 2)..<cursor])
                        if let classCharacters = posixClassCharacters(named: className) {
                            output.append(contentsOf: classCharacters)
                            index = cursor + 2
                            consumedPOSIXClass = true
                        }
                        break
                    }
                    cursor += 1
                }
            }

            if consumedPOSIXClass {
                continue
            }

            if index + 2 < unescaped.count, unescaped[index + 1] == "-",
               let expandedRange = expandRange(start: unescaped[index], end: unescaped[index + 2]) {
                output.append(contentsOf: expandedRange)
                index += 3
                continue
            }

            output.append(unescaped[index])
            index += 1
        }
        return output
    }

    private static func posixClassCharacters(named className: String) -> [Character]? {
        switch className.lowercased() {
        case "lower":
            return expandRange(start: "a", end: "z")
        case "upper":
            return expandRange(start: "A", end: "Z")
        case "digit":
            return expandRange(start: "0", end: "9")
        case "alpha":
            return (expandRange(start: "A", end: "Z") ?? []) + (expandRange(start: "a", end: "z") ?? [])
        case "alnum":
            return (expandRange(start: "A", end: "Z") ?? [])
                + (expandRange(start: "a", end: "z") ?? [])
                + (expandRange(start: "0", end: "9") ?? [])
        case "space":
            return [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
        default:
            return nil
        }
    }

    private static func decodeEscapes(_ raw: String) -> [Character] {
        var output: [Character] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\\", raw.index(after: index) < raw.endIndex {
                let nextIndex = raw.index(after: index)
                let escaped = raw[nextIndex]
                switch escaped {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "r": output.append("\r")
                case "\\": output.append("\\")
                default: output.append(escaped)
                }
                index = raw.index(after: nextIndex)
                continue
            }

            output.append(character)
            index = raw.index(after: index)
        }
        return output
    }

    private static func expandRange(start: Character, end: Character) -> [Character]? {
        guard let startScalar = singleScalar(for: start), let endScalar = singleScalar(for: end) else {
            return nil
        }

        if startScalar.value <= endScalar.value {
            return (startScalar.value...endScalar.value).compactMap {
                UnicodeScalar($0).map(Character.init)
            }
        }

        return (endScalar.value...startScalar.value).reversed().compactMap {
            UnicodeScalar($0).map(Character.init)
        }
    }

    private static func singleScalar(for character: Character) -> UnicodeScalar? {
        let scalars = Array(String(character).unicodeScalars)
        guard scalars.count == 1 else {
            return nil
        }
        return scalars[0]
    }
}

private struct SelectionRange {
    let start: Int?
    let end: Int?

    func contains(_ index: Int) -> Bool {
        if let start, index < start {
            return false
        }
        if let end, index > end {
            return false
        }
        return true
    }
}

private func parseSelectionRanges(_ spec: String) -> [SelectionRange]? {
    let tokens = spec.split(separator: ",").map(String.init)
    guard !tokens.isEmpty else {
        return nil
    }

    var ranges: [SelectionRange] = []
    for token in tokens where !token.isEmpty {
        if token.contains("-") {
            let pieces = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pieces.count == 2 else {
                return nil
            }

            let left = pieces[0].isEmpty ? nil : Int(pieces[0])
            let right = pieces[1].isEmpty ? nil : Int(pieces[1])

            if left == nil, right == nil {
                return nil
            }
            if let left, left <= 0 {
                return nil
            }
            if let right, right <= 0 {
                return nil
            }
            if let left, let right, left > right {
                return nil
            }
            ranges.append(SelectionRange(start: left, end: right))
        } else if let value = Int(token), value > 0 {
            ranges.append(SelectionRange(start: value, end: value))
        } else {
            return nil
        }
    }

    return ranges.isEmpty ? nil : ranges
}

private func selectIndexes(totalCount: Int, ranges: [SelectionRange]) -> [Int] {
    guard totalCount > 0 else {
        return []
    }

    var selected: [Int] = []
    for index in 1...totalCount {
        if ranges.contains(where: { $0.contains(index) }) {
            selected.append(index)
        }
    }
    return selected
}
