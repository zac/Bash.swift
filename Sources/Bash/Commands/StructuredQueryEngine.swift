import Foundation

struct StructuredQueryProgram {
    private let expression: StructuredQueryExpression

    static func parse(_ source: String) throws -> StructuredQueryProgram {
        var parser = try StructuredQueryParser(source: source)
        return StructuredQueryProgram(expression: try parser.parse())
    }

    func evaluate(input: Any) throws -> [Any] {
        try StructuredQueryEvaluator.evaluate(expression, input: input)
    }
}

struct StructuredQueryRenderOptions {
    let rawOutput: Bool
    let compactOutput: Bool
    let sortKeys: Bool
}

enum StructuredQueryRenderer {
    static func render(_ value: Any, options: StructuredQueryRenderOptions) throws -> String {
        if options.rawOutput, let string = value as? String {
            return string
        }

        var writing: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        if !options.compactOutput {
            writing.insert(.prettyPrinted)
        }
        if options.sortKeys {
            writing.insert(.sortedKeys)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: writing)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ShellError.unsupported("unable to render query result")
        }
    }
}

private indirect enum StructuredQueryExpression {
    case identity
    case literal(Any)
    case path(base: StructuredQueryExpression, operations: [PathOperation])
    case pipe(StructuredQueryExpression, StructuredQueryExpression)
    case binary(BinaryOperator, StructuredQueryExpression, StructuredQueryExpression)
    case unary(UnaryOperator, StructuredQueryExpression)
    case select(StructuredQueryExpression)
    case collect(StructuredQueryExpression)
}

private enum PathOperation {
    case key(String)
    case index(Int)
    case iterate
}

private enum BinaryOperator {
    case equal
    case notEqual
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case and
    case or
    case coalesce
}

private enum UnaryOperator {
    case not
}

private enum StructuredQueryToken: Equatable {
    case dot
    case identifier(String)
    case string(String)
    case number(Double)
    case leftParen
    case rightParen
    case leftBracket
    case rightBracket
    case comma
    case pipe
    case equalEqual
    case bangEqual
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case coalesce
    case keywordAnd
    case keywordOr
    case keywordNot
    case end
}

private struct StructuredQueryLexer {
    private let characters: [Character]
    private var index: Int = 0

    init(source: String) {
        characters = Array(source)
    }

    mutating func tokenize() throws -> [StructuredQueryToken] {
        var tokens: [StructuredQueryToken] = []

        while true {
            skipWhitespace()
            guard let character = current else {
                break
            }

            switch character {
            case ".":
                advance()
                tokens.append(.dot)

            case "(":
                advance()
                tokens.append(.leftParen)

            case ")":
                advance()
                tokens.append(.rightParen)

            case "[":
                advance()
                tokens.append(.leftBracket)

            case "]":
                advance()
                tokens.append(.rightBracket)

            case ",":
                advance()
                tokens.append(.comma)

            case "|":
                advance()
                tokens.append(.pipe)

            case "/":
                advance()
                if consume("/") {
                    tokens.append(.coalesce)
                } else {
                    throw ShellError.unsupported("invalid query token '/'")
                }

            case "=":
                advance()
                if consume("=") {
                    tokens.append(.equalEqual)
                } else {
                    throw ShellError.unsupported("invalid query token '='")
                }

            case "!":
                advance()
                if consume("=") {
                    tokens.append(.bangEqual)
                } else {
                    throw ShellError.unsupported("invalid query token '!'")
                }

            case "<":
                advance()
                if consume("=") {
                    tokens.append(.lessThanOrEqual)
                } else {
                    tokens.append(.lessThan)
                }

            case ">":
                advance()
                if consume("=") {
                    tokens.append(.greaterThanOrEqual)
                } else {
                    tokens.append(.greaterThan)
                }

            case "\"", "'":
                let value = try readString(quote: character)
                tokens.append(.string(value))

            case "-", "0"..."9":
                let value = try readNumber()
                tokens.append(.number(value))

            default:
                if isIdentifierHead(character) {
                    let identifier = readIdentifier()
                    switch identifier {
                    case "and":
                        tokens.append(.keywordAnd)
                    case "or":
                        tokens.append(.keywordOr)
                    case "not":
                        tokens.append(.keywordNot)
                    default:
                        tokens.append(.identifier(identifier))
                    }
                } else {
                    throw ShellError.unsupported("invalid query token '\(character)'")
                }
            }
        }

        tokens.append(.end)
        return tokens
    }

    private var current: Character? {
        guard index < characters.count else {
            return nil
        }
        return characters[index]
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard current == character else {
            return false
        }
        advance()
        return true
    }

    private mutating func skipWhitespace() {
        while let character = current, character.isWhitespace {
            advance()
        }
    }

    private func isIdentifierHead(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierBody(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber || character == "-"
    }

    private mutating func readIdentifier() -> String {
        let start = index
        advance()
        while let character = current, isIdentifierBody(character) {
            advance()
        }
        return String(characters[start..<index])
    }

    private mutating func readString(quote: Character) throws -> String {
        advance() // opening quote
        var output = ""

        while let character = current {
            advance()
            if character == quote {
                return output
            }
            if character == "\\" {
                guard let escaped = current else {
                    throw ShellError.unsupported("unterminated string literal")
                }
                advance()
                switch escaped {
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
                case "'":
                    output.append("'")
                default:
                    output.append(escaped)
                }
                continue
            }
            output.append(character)
        }

        throw ShellError.unsupported("unterminated string literal")
    }

    private mutating func readNumber() throws -> Double {
        let start = index
        if current == "-" {
            advance()
        }

        var hasDigits = false
        while let character = current, character.isNumber {
            hasDigits = true
            advance()
        }

        if current == "." {
            advance()
            while let character = current, character.isNumber {
                hasDigits = true
                advance()
            }
        }

        guard hasDigits else {
            throw ShellError.unsupported("invalid number literal")
        }

        if let character = current, character == "e" || character == "E" {
            advance()
            if let sign = current, sign == "+" || sign == "-" {
                advance()
            }

            var exponentDigits = false
            while let digit = current, digit.isNumber {
                exponentDigits = true
                advance()
            }
            guard exponentDigits else {
                throw ShellError.unsupported("invalid number literal")
            }
        }

        let token = String(characters[start..<index])
        guard let value = Double(token) else {
            throw ShellError.unsupported("invalid number literal")
        }
        return value
    }
}

private struct StructuredQueryParser {
    private let tokens: [StructuredQueryToken]
    private var index: Int = 0

    init(source: String) throws {
        var lexer = StructuredQueryLexer(source: source)
        tokens = try lexer.tokenize()
    }

    mutating func parse() throws -> StructuredQueryExpression {
        let expression = try parseExpression(minimumPrecedence: 0)
        try expect(.end)
        return expression
    }

    private mutating func parseExpression(minimumPrecedence: Int) throws -> StructuredQueryExpression {
        var expression = try parsePrefix()
        expression = try parsePostfix(expression)

        while let infix = currentInfix(), infix.precedence >= minimumPrecedence {
            _ = advance()
            let nextMinimum = infix.isLeftAssociative ? infix.precedence + 1 : infix.precedence
            var rhs = try parseExpression(minimumPrecedence: nextMinimum)
            rhs = try parsePostfix(rhs)
            expression = infix.makeExpression(expression, rhs)
        }

        return expression
    }

    private mutating func parsePrefix() throws -> StructuredQueryExpression {
        let token = current
        switch token {
        case .dot:
            _ = advance()
            var expression: StructuredQueryExpression = .identity
            if consume(.leftBracket) {
                let operation = try parseBracketOperation()
                expression = appendPathOperation(operation, to: expression)
            } else if let identifier = consumePathIdentifier() {
                expression = appendPathOperation(.key(identifier), to: expression)
            }
            return expression

        case .number(let number):
            _ = advance()
            if number.rounded(.towardZero) == number {
                return .literal(Int(number))
            }
            return .literal(number)

        case .string(let string):
            _ = advance()
            return .literal(string)

        case .identifier(let name):
            _ = advance()
            if name == "true" {
                return .literal(true)
            }
            if name == "false" {
                return .literal(false)
            }
            if name == "null" {
                return .literal(NSNull())
            }
            if name == "select" {
                try expect(.leftParen)
                let condition = try parseExpression(minimumPrecedence: 0)
                try expect(.rightParen)
                return .select(condition)
            }
            throw ShellError.unsupported("unsupported identifier: \(name)")

        case .keywordNot:
            _ = advance()
            let operand = try parseExpression(minimumPrecedence: 60)
            return .unary(.not, operand)

        case .leftParen:
            _ = advance()
            let inner = try parseExpression(minimumPrecedence: 0)
            try expect(.rightParen)
            return inner

        case .leftBracket:
            _ = advance()
            if consume(.rightBracket) {
                return .literal([Any]())
            }
            let inner = try parseExpression(minimumPrecedence: 0)
            try expect(.rightBracket)
            return .collect(inner)

        default:
            throw ShellError.unsupported("invalid query expression")
        }
    }

    private mutating func parsePostfix(_ base: StructuredQueryExpression) throws -> StructuredQueryExpression {
        var expression = base
        while true {
            if consume(.dot) {
                let operation = try parseDotOperation()
                expression = appendPathOperation(operation, to: expression)
                continue
            }

            if consume(.leftBracket) {
                let operation = try parseBracketOperation()
                expression = appendPathOperation(operation, to: expression)
                continue
            }

            break
        }
        return expression
    }

    private mutating func parseDotOperation() throws -> PathOperation {
        if consume(.leftBracket) {
            return try parseBracketOperation()
        }
        if let identifier = consumePathIdentifier() {
            return .key(identifier)
        }
        throw ShellError.unsupported("invalid field access after '.'")
    }

    private mutating func parseBracketOperation() throws -> PathOperation {
        defer {
            _ = consume(.rightBracket)
        }

        if consume(.rightBracket) {
            return .iterate
        }

        switch current {
        case .number(let number):
            _ = advance()
            guard number.rounded(.towardZero) == number else {
                throw ShellError.unsupported("array index must be an integer")
            }
            try expect(.rightBracket)
            return .index(Int(number))

        case .string(let key):
            _ = advance()
            try expect(.rightBracket)
            return .key(key)

        default:
            throw ShellError.unsupported("unsupported [] selector")
        }
    }

    private func appendPathOperation(_ operation: PathOperation, to expression: StructuredQueryExpression) -> StructuredQueryExpression {
        if case let .path(base, existingOperations) = expression {
            return .path(base: base, operations: existingOperations + [operation])
        }
        return .path(base: expression, operations: [operation])
    }

    private mutating func consumePathIdentifier() -> String? {
        switch current {
        case .identifier(let name):
            _ = advance()
            return name
        case .keywordAnd:
            _ = advance()
            return "and"
        case .keywordOr:
            _ = advance()
            return "or"
        case .keywordNot:
            _ = advance()
            return "not"
        default:
            return nil
        }
    }

    private mutating func expect(_ token: StructuredQueryToken) throws {
        guard current == token else {
            throw ShellError.unsupported("invalid query syntax")
        }
        _ = advance()
    }

    @discardableResult
    private mutating func consume(_ token: StructuredQueryToken) -> Bool {
        guard current == token else {
            return false
        }
        _ = advance()
        return true
    }

    private var current: StructuredQueryToken {
        tokens[min(index, tokens.count - 1)]
    }

    @discardableResult
    private mutating func advance() -> StructuredQueryToken {
        let token = current
        index += 1
        return token
    }

    private func currentInfix() -> InfixDescriptor? {
        switch current {
        case .pipe:
            return InfixDescriptor(precedence: 10, isLeftAssociative: true) { .pipe($0, $1) }
        case .keywordOr:
            return InfixDescriptor(precedence: 20, isLeftAssociative: true) { .binary(.or, $0, $1) }
        case .keywordAnd:
            return InfixDescriptor(precedence: 30, isLeftAssociative: true) { .binary(.and, $0, $1) }
        case .coalesce:
            return InfixDescriptor(precedence: 40, isLeftAssociative: true) { .binary(.coalesce, $0, $1) }
        case .equalEqual:
            return InfixDescriptor(precedence: 50, isLeftAssociative: true) { .binary(.equal, $0, $1) }
        case .bangEqual:
            return InfixDescriptor(precedence: 50, isLeftAssociative: true) { .binary(.notEqual, $0, $1) }
        case .lessThan:
            return InfixDescriptor(precedence: 50, isLeftAssociative: true) { .binary(.lessThan, $0, $1) }
        case .lessThanOrEqual:
            return InfixDescriptor(precedence: 50, isLeftAssociative: true) { .binary(.lessThanOrEqual, $0, $1) }
        case .greaterThan:
            return InfixDescriptor(precedence: 50, isLeftAssociative: true) { .binary(.greaterThan, $0, $1) }
        case .greaterThanOrEqual:
            return InfixDescriptor(precedence: 50, isLeftAssociative: true) { .binary(.greaterThanOrEqual, $0, $1) }
        default:
            return nil
        }
    }

    private struct InfixDescriptor {
        let precedence: Int
        let isLeftAssociative: Bool
        let makeExpression: (StructuredQueryExpression, StructuredQueryExpression) -> StructuredQueryExpression
    }
}

private enum StructuredQueryEvaluator {
    static func evaluate(_ expression: StructuredQueryExpression, input: Any) throws -> [Any] {
        switch expression {
        case .identity:
            return [input]

        case .literal(let value):
            return [value]

        case .collect(let child):
            return [try evaluate(child, input: input)]

        case .path(let base, let operations):
            var values = try evaluate(base, input: input)
            for operation in operations {
                values = applyPathOperation(operation, to: values)
            }
            return values

        case .pipe(let lhs, let rhs):
            var output: [Any] = []
            for value in try evaluate(lhs, input: input) {
                output.append(contentsOf: try evaluate(rhs, input: value))
            }
            return output

        case .unary(let operation, let operand):
            switch operation {
            case .not:
                return [!isTruthy(firstValue(from: try evaluate(operand, input: input)))]
            }

        case .select(let predicate):
            let predicateValues = try evaluate(predicate, input: input)
            if predicateValues.contains(where: isTruthy) {
                return [input]
            }
            return []

        case .binary(let operation, let lhs, let rhs):
            return [try evaluateBinary(operation, lhs: lhs, rhs: rhs, input: input)]
        }
    }

    private static func applyPathOperation(_ operation: PathOperation, to values: [Any]) -> [Any] {
        switch operation {
        case .key(let key):
            return values.map { value in
                guard let object = value as? [String: Any] else {
                    return NSNull()
                }
                return object[key] ?? NSNull()
            }

        case .index(let index):
            return values.map { value in
                guard let array = value as? [Any], !array.isEmpty else {
                    return NSNull()
                }
                let resolved = index >= 0 ? index : (array.count + index)
                guard resolved >= 0, resolved < array.count else {
                    return NSNull()
                }
                return array[resolved]
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
            return expanded
        }
    }

    private static func evaluateBinary(
        _ operation: BinaryOperator,
        lhs: StructuredQueryExpression,
        rhs: StructuredQueryExpression,
        input: Any
    ) throws -> Any {
        switch operation {
        case .and:
            let leftValue = firstValue(from: try evaluate(lhs, input: input))
            if !isTruthy(leftValue) {
                return false
            }
            let rightValue = firstValue(from: try evaluate(rhs, input: input))
            return isTruthy(rightValue)

        case .or:
            let leftValue = firstValue(from: try evaluate(lhs, input: input))
            if isTruthy(leftValue) {
                return true
            }
            let rightValue = firstValue(from: try evaluate(rhs, input: input))
            return isTruthy(rightValue)

        case .coalesce:
            let leftValues = try evaluate(lhs, input: input)
            if let firstNonNull = leftValues.first(where: { !isNullLike($0) }) {
                return firstNonNull
            }
            return firstValue(from: try evaluate(rhs, input: input))

        case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            let leftValue = firstValue(from: try evaluate(lhs, input: input))
            let rightValue = firstValue(from: try evaluate(rhs, input: input))
            return compare(leftValue, rightValue, operation: operation)
        }
    }

    private static func compare(_ lhs: Any, _ rhs: Any, operation: BinaryOperator) -> Bool {
        switch operation {
        case .equal:
            return deepEqual(lhs, rhs)
        case .notEqual:
            return !deepEqual(lhs, rhs)
        case .lessThan:
            return orderedCompare(lhs, rhs) == .orderedAscending
        case .lessThanOrEqual:
            let result = orderedCompare(lhs, rhs)
            return result == .orderedAscending || result == .orderedSame
        case .greaterThan:
            return orderedCompare(lhs, rhs) == .orderedDescending
        case .greaterThanOrEqual:
            let result = orderedCompare(lhs, rhs)
            return result == .orderedDescending || result == .orderedSame
        case .and, .or, .coalesce:
            return false
        }
    }

    private static func orderedCompare(_ lhs: Any, _ rhs: Any) -> ComparisonResult {
        if let l = asDouble(lhs), let r = asDouble(rhs) {
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }
        if let l = lhs as? String, let r = rhs as? String {
            return l.compare(r)
        }
        if let l = lhs as? Bool, let r = rhs as? Bool {
            if l == r { return .orderedSame }
            return l ? .orderedDescending : .orderedAscending
        }
        return .orderedSame
    }

    private static func deepEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if isNullLike(lhs) && isNullLike(rhs) {
            return true
        }

        if let l = lhs as? Bool, let r = rhs as? Bool {
            return l == r
        }

        if let l = asDouble(lhs), let r = asDouble(rhs) {
            return l == r
        }

        if let l = lhs as? String, let r = rhs as? String {
            return l == r
        }

        if let l = lhs as? [Any], let r = rhs as? [Any] {
            guard l.count == r.count else {
                return false
            }
            for (left, right) in zip(l, r) where !deepEqual(left, right) {
                return false
            }
            return true
        }

        if let l = lhs as? [String: Any], let r = rhs as? [String: Any] {
            guard l.keys.count == r.keys.count else {
                return false
            }
            for key in l.keys {
                guard let right = r[key], deepEqual(l[key] as Any, right) else {
                    return false
                }
            }
            return true
        }

        return false
    }

    private static func asDouble(_ value: Any) -> Double? {
        if let number = value as? Double {
            return number
        }
        if let number = value as? Int {
            return Double(number)
        }
        if let number = value as? Int64 {
            return Double(number)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return number.doubleValue
        }
        return nil
    }

    private static func firstValue(from values: [Any]) -> Any {
        values.first ?? NSNull()
    }

    private static func isNullLike(_ value: Any) -> Bool {
        (value as? NSNull) != nil
    }

    private static func isTruthy(_ value: Any) -> Bool {
        if isNullLike(value) {
            return false
        }
        if let boolean = value as? Bool {
            return boolean
        }
        return true
    }
}
