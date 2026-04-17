import Foundation

package enum ArithmeticEvaluator {
    private enum Token {
        case number(Int)
        case identifier(String)
        case op(String)
        case lparen
        case rparen
    }

    package static func evaluate(_ raw: String, environment: [String: String]) -> Int? {
        guard let tokens = tokenize(raw) else {
            return nil
        }

        var parser = Parser(tokens: tokens, environment: environment)
        return parser.parse()
    }

    private static func tokenize(_ raw: String) -> [Token]? {
        let chars = Array(raw)
        var tokens: [Token] = []
        var index = 0

        func starts(with value: String) -> Bool {
            let end = index + value.count
            guard end <= chars.count else {
                return false
            }
            return String(chars[index..<end]) == value
        }

        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                index += 1
                continue
            }

            if starts(with: "&&") || starts(with: "||") ||
                starts(with: "==") || starts(with: "!=") ||
                starts(with: "<=") || starts(with: ">=") ||
                starts(with: "<<") || starts(with: ">>") ||
                starts(with: "**") {
                let op = String(chars[index..<(index + 2)])
                tokens.append(.op(op))
                index += 2
                continue
            }

            if char == "(" {
                tokens.append(.lparen)
                index += 1
                continue
            }

            if char == ")" {
                tokens.append(.rparen)
                index += 1
                continue
            }

            if "+-*/%<>&|^!~".contains(char) {
                tokens.append(.op(String(char)))
                index += 1
                continue
            }

            if char.isNumber {
                var value = String(char)
                index += 1
                while index < chars.count, chars[index].isNumber {
                    value.append(chars[index])
                    index += 1
                }

                guard let number = Int(value) else {
                    return nil
                }
                tokens.append(.number(number))
                continue
            }

            if isIdentifierStart(char) {
                var name = String(char)
                index += 1
                while index < chars.count, isIdentifierBody(chars[index]) {
                    name.append(chars[index])
                    index += 1
                }
                tokens.append(.identifier(name))
                continue
            }

            return nil
        }

        return tokens
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private struct Parser {
        let tokens: [Token]
        let environment: [String: String]
        var index: Int = 0

        mutating func parse() -> Int? {
            guard let value = parseLogicalOr(), index == tokens.count else {
                return nil
            }
            return value
        }

        mutating func parseLogicalOr() -> Int? {
            guard var value = parseLogicalAnd() else {
                return nil
            }

            while matchOperator("||") {
                guard let rhs = parseLogicalAnd() else {
                    return nil
                }
                value = (value != 0 || rhs != 0) ? 1 : 0
            }
            return value
        }

        mutating func parseLogicalAnd() -> Int? {
            guard var value = parseBitwiseOr() else {
                return nil
            }

            while matchOperator("&&") {
                guard let rhs = parseBitwiseOr() else {
                    return nil
                }
                value = (value != 0 && rhs != 0) ? 1 : 0
            }
            return value
        }

        mutating func parseBitwiseOr() -> Int? {
            guard var value = parseBitwiseXor() else {
                return nil
            }

            while matchOperator("|") {
                guard let rhs = parseBitwiseXor() else {
                    return nil
                }
                value |= rhs
            }
            return value
        }

        mutating func parseBitwiseXor() -> Int? {
            guard var value = parseBitwiseAnd() else {
                return nil
            }

            while matchOperator("^") {
                guard let rhs = parseBitwiseAnd() else {
                    return nil
                }
                value ^= rhs
            }
            return value
        }

        mutating func parseBitwiseAnd() -> Int? {
            guard var value = parseEquality() else {
                return nil
            }

            while matchOperator("&") {
                guard let rhs = parseEquality() else {
                    return nil
                }
                value &= rhs
            }
            return value
        }

        mutating func parseEquality() -> Int? {
            guard var value = parseRelational() else {
                return nil
            }

            while true {
                if matchOperator("==") {
                    guard let rhs = parseRelational() else {
                        return nil
                    }
                    value = value == rhs ? 1 : 0
                    continue
                }
                if matchOperator("!=") {
                    guard let rhs = parseRelational() else {
                        return nil
                    }
                    value = value != rhs ? 1 : 0
                    continue
                }
                return value
            }
        }

        mutating func parseRelational() -> Int? {
            guard var value = parseShift() else {
                return nil
            }

            while true {
                if matchOperator("<") {
                    guard let rhs = parseShift() else {
                        return nil
                    }
                    value = value < rhs ? 1 : 0
                    continue
                }
                if matchOperator("<=") {
                    guard let rhs = parseShift() else {
                        return nil
                    }
                    value = value <= rhs ? 1 : 0
                    continue
                }
                if matchOperator(">") {
                    guard let rhs = parseShift() else {
                        return nil
                    }
                    value = value > rhs ? 1 : 0
                    continue
                }
                if matchOperator(">=") {
                    guard let rhs = parseShift() else {
                        return nil
                    }
                    value = value >= rhs ? 1 : 0
                    continue
                }
                return value
            }
        }

        mutating func parseShift() -> Int? {
            guard var value = parseAdditive() else {
                return nil
            }

            while true {
                if matchOperator("<<") {
                    guard let rhs = parseAdditive(), rhs >= 0 else {
                        return nil
                    }
                    value <<= rhs
                    continue
                }
                if matchOperator(">>") {
                    guard let rhs = parseAdditive(), rhs >= 0 else {
                        return nil
                    }
                    value >>= rhs
                    continue
                }
                return value
            }
        }

        mutating func parseAdditive() -> Int? {
            guard var value = parseMultiplicative() else {
                return nil
            }

            while true {
                if matchOperator("+") {
                    guard let rhs = parseMultiplicative() else {
                        return nil
                    }
                    value += rhs
                    continue
                }
                if matchOperator("-") {
                    guard let rhs = parseMultiplicative() else {
                        return nil
                    }
                    value -= rhs
                    continue
                }
                return value
            }
        }

        mutating func parseMultiplicative() -> Int? {
            guard var value = parsePower() else {
                return nil
            }

            while true {
                if matchOperator("*") {
                    guard let rhs = parsePower() else {
                        return nil
                    }
                    value *= rhs
                    continue
                }
                if matchOperator("/") {
                    guard let rhs = parsePower(), rhs != 0 else {
                        return nil
                    }
                    value /= rhs
                    continue
                }
                if matchOperator("%") {
                    guard let rhs = parsePower(), rhs != 0 else {
                        return nil
                    }
                    value %= rhs
                    continue
                }
                return value
            }
        }

        mutating func parsePower() -> Int? {
            guard var value = parseUnary() else {
                return nil
            }

            if matchOperator("**") {
                guard let exponent = parsePower(), exponent >= 0 else {
                    return nil
                }
                value = intPower(value, exponent)
            }
            return value
        }

        mutating func parseUnary() -> Int? {
            if matchOperator("+") {
                return parseUnary()
            }
            if matchOperator("-") {
                guard let value = parseUnary() else {
                    return nil
                }
                return -value
            }
            if matchOperator("!") {
                guard let value = parseUnary() else {
                    return nil
                }
                return value == 0 ? 1 : 0
            }
            if matchOperator("~") {
                guard let value = parseUnary() else {
                    return nil
                }
                return ~value
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Int? {
            guard let token = currentToken() else {
                return nil
            }

            switch token {
            case let .number(value):
                index += 1
                return value
            case let .identifier(name):
                index += 1
                return Int(environment[name] ?? "") ?? 0
            case .lparen:
                index += 1
                guard let value = parseLogicalOr() else {
                    return nil
                }
                guard matchRightParen() else {
                    return nil
                }
                return value
            case .rparen, .op:
                return nil
            }
        }

        mutating func matchOperator(_ op: String) -> Bool {
            guard let token = currentToken(),
                  case let .op(value) = token,
                  value == op else {
                return false
            }
            index += 1
            return true
        }

        mutating func matchRightParen() -> Bool {
            guard let token = currentToken(), case .rparen = token else {
                return false
            }
            index += 1
            return true
        }

        func currentToken() -> Token? {
            guard index < tokens.count else {
                return nil
            }
            return tokens[index]
        }

        func intPower(_ base: Int, _ exponent: Int) -> Int {
            if exponent == 0 {
                return 1
            }

            var result = 1
            var factor = base
            var power = exponent
            while power > 0 {
                if power & 1 == 1 {
                    result *= factor
                }
                power >>= 1
                if power > 0 {
                    factor *= factor
                }
            }
            return result
        }
    }
}
