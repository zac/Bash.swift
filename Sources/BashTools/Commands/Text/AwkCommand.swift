import ArgumentParser
import Foundation
import BashCore

struct AwkCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .customShort("F"), help: "Field separator")
        var fieldSeparator: String?

        @Argument(help: "AWK program")
        var program: String

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "awk"
    static let overview = "Pattern scanning and processing language"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let program: Program
        do {
            program = try parseProgram(options.program)
        } catch let error as ShellError {
            context.writeStderr("awk: \(error)\n")
            return 2
        } catch {
            context.writeStderr("awk: unsupported program\n")
            return 2
        }

        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        var lineNumber = 0

        for action in program.begin {
            context.writeStdout(action.render(with: LineContext(line: "", lineNumber: 0, fields: [])) + "\n")
        }

        for content in inputs.contents {
            for line in lines(from: content) {
                lineNumber += 1
                let fields = splitFields(line: line, separator: options.fieldSeparator)
                let lineContext = LineContext(line: line, lineNumber: lineNumber, fields: fields)

                if program.rule.matches(lineContext) {
                    context.writeStdout(program.rule.action.render(with: lineContext) + "\n")
                }
            }
        }

        if inputs.hadError {
            return 1
        }

        for action in program.end {
            context.writeStdout(action.render(with: LineContext(line: "", lineNumber: lineNumber, fields: [])) + "\n")
        }

        return 0
    }

    private struct LineContext {
        let line: String
        let lineNumber: Int
        let fields: [String]

        var nf: Int { fields.count }

        func field(_ index: Int) -> String {
            if index == 0 { return line }
            guard index > 0, index <= fields.count else { return "" }
            return fields[index - 1]
        }
    }

    private struct Program {
        let begin: [PrintAction]
        let rule: Rule
        let end: [PrintAction]
    }

    private struct Rule {
        let predicate: Predicate
        let action: PrintAction

        func matches(_ context: LineContext) -> Bool {
            predicate.matches(context)
        }
    }

    private enum Predicate {
        case always
        case regex(NSRegularExpression)
        case comparison(lhs: ValueRef, op: ComparisonOperator, rhs: Value)

        func matches(_ context: LineContext) -> Bool {
            switch self {
            case .always:
                return true
            case let .regex(regex):
                let range = NSRange(context.line.startIndex..<context.line.endIndex, in: context.line)
                return regex.firstMatch(in: context.line, range: range) != nil
            case let .comparison(lhs, op, rhs):
                let lhsValue = lhs.resolve(in: context)
                let rhsValue = rhs.resolve(in: context)
                return op.evaluate(lhs: lhsValue, rhs: rhsValue)
            }
        }
    }

    private enum ComparisonOperator: String {
        case equal = "=="
        case notEqual = "!="
        case greater = ">"
        case less = "<"
        case greaterOrEqual = ">="
        case lessOrEqual = "<="

        func evaluate(lhs: String, rhs: String) -> Bool {
            if let leftNumeric = Double(lhs), let rightNumeric = Double(rhs) {
                switch self {
                case .equal: return leftNumeric == rightNumeric
                case .notEqual: return leftNumeric != rightNumeric
                case .greater: return leftNumeric > rightNumeric
                case .less: return leftNumeric < rightNumeric
                case .greaterOrEqual: return leftNumeric >= rightNumeric
                case .lessOrEqual: return leftNumeric <= rightNumeric
                }
            }

            switch self {
            case .equal: return lhs == rhs
            case .notEqual: return lhs != rhs
            case .greater: return lhs > rhs
            case .less: return lhs < rhs
            case .greaterOrEqual: return lhs >= rhs
            case .lessOrEqual: return lhs <= rhs
            }
        }
    }

    private enum ValueRef {
        case field(Int)
        case nr
        case nf

        func resolve(in context: LineContext) -> String {
            switch self {
            case let .field(index):
                return context.field(index)
            case .nr:
                return String(context.lineNumber)
            case .nf:
                return String(context.nf)
            }
        }
    }

    private enum Value {
        case literal(String)
        case ref(ValueRef)

        func resolve(in context: LineContext) -> String {
            switch self {
            case let .literal(value):
                return value
            case let .ref(reference):
                return reference.resolve(in: context)
            }
        }
    }

    private struct PrintAction {
        let terms: [Value]

        func render(with context: LineContext) -> String {
            if terms.isEmpty {
                return context.line
            }
            return terms.map { $0.resolve(in: context) }.joined(separator: " ")
        }
    }

    private static func parseProgram(_ source: String) throws -> Program {
        var remaining = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let beginActions = try extractActions(keyword: "BEGIN", source: &remaining)
        let endActions = try extractActions(keyword: "END", source: &remaining)

        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule: Rule
        if trimmed.isEmpty {
            rule = Rule(predicate: .always, action: PrintAction(terms: []))
        } else {
            rule = try parseMainRule(trimmed)
        }

        return Program(begin: beginActions, rule: rule, end: endActions)
    }

    private static func extractActions(keyword: String, source: inout String) throws -> [PrintAction] {
        let pattern = "\(keyword)\\s*\\{([^}]*)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        let matches = regex.matches(in: source, range: range)
        guard !matches.isEmpty else {
            return []
        }

        var actions: [PrintAction] = []
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let body = nsSource.substring(with: match.range(at: 1))
            actions.append(try parsePrintAction(body))
        }

        source = regex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
        return actions
    }

    private static func parseMainRule(_ source: String) throws -> Rule {
        if let body = capture(pattern: #"^\{\s*(.*)\s*\}$"#, from: source, group: 1) {
            return Rule(predicate: .always, action: try parsePrintAction(body))
        }

        guard let predicateText = capture(pattern: #"^(.*)\{\s*(.*)\s*\}$"#, from: source, group: 1),
              let body = capture(pattern: #"^(.*)\{\s*(.*)\s*\}$"#, from: source, group: 2)
        else {
            throw ShellError.unsupported("unsupported program")
        }

        return Rule(
            predicate: try parsePredicate(predicateText.trimmingCharacters(in: .whitespacesAndNewlines)),
            action: try parsePrintAction(body)
        )
    }

    private static func parsePredicate(_ source: String) throws -> Predicate {
        if source.isEmpty {
            return .always
        }

        if source.hasPrefix("/"), source.hasSuffix("/"), source.count >= 2 {
            let start = source.index(after: source.startIndex)
            let end = source.index(before: source.endIndex)
            return .regex(try NSRegularExpression(pattern: String(source[start..<end])))
        }

        if let lhs = capture(pattern: #"^(\$[0-9]+|\$0|NF|NR)\s*(==|!=|>=|<=|>|<)\s*(.+)$"#, from: source, group: 1),
           let opText = capture(pattern: #"^(\$[0-9]+|\$0|NF|NR)\s*(==|!=|>=|<=|>|<)\s*(.+)$"#, from: source, group: 2),
           let rhsText = capture(pattern: #"^(\$[0-9]+|\$0|NF|NR)\s*(==|!=|>=|<=|>|<)\s*(.+)$"#, from: source, group: 3),
           let op = ComparisonOperator(rawValue: opText)
        {
            return .comparison(
                lhs: try parseReference(lhs),
                op: op,
                rhs: try parseValue(rhsText.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }

        return .regex(try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: source)))
    }

    private static func parsePrintAction(_ source: String) throws -> PrintAction {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("print") else {
            throw ShellError.unsupported("only print actions are supported")
        }

        let expression = trimmed.dropFirst("print".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if expression.isEmpty {
            return PrintAction(terms: [])
        }

        let tokens = tokenizeExpression(expression)
        let terms = try tokens.map { token in
            try parseValue(token)
        }
        return PrintAction(terms: terms)
    }

    private static func tokenizeExpression(_ expression: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for char in expression {
            if let activeQuote = quote {
                if char == activeQuote {
                    current.append(char)
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\"" || char == "'" {
                quote = char
                current.append(char)
                continue
            }

            if char == "," || char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func parseValue(_ token: String) throws -> Value {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let start = trimmed.index(after: trimmed.startIndex)
            let end = trimmed.index(before: trimmed.endIndex)
            return .literal(String(trimmed[start..<end]))
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            let start = trimmed.index(after: trimmed.startIndex)
            let end = trimmed.index(before: trimmed.endIndex)
            return .literal(String(trimmed[start..<end]))
        }

        if let reference = try? parseReference(trimmed) {
            return .ref(reference)
        }

        return .literal(trimmed)
    }

    private static func parseReference(_ token: String) throws -> ValueRef {
        if token == "NF" {
            return .nf
        }
        if token == "NR" {
            return .nr
        }
        if token.hasPrefix("$"), let index = Int(token.dropFirst()) {
            return .field(index)
        }
        throw ShellError.unsupported("unsupported value reference")
    }

    private static func capture(pattern: String, from source: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges > group,
              let swiftRange = Range(match.range(at: group), in: source)
        else {
            return nil
        }
        return String(source[swiftRange])
    }

    private static func splitFields(line: String, separator: String?) -> [String] {
        if let separator {
            if separator.isEmpty {
                return line.map(String.init)
            }
            return line.components(separatedBy: separator)
        }
        return line.split(whereSeparator: \.isWhitespace).map(String.init)
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
}

