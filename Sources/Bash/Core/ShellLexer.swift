import Foundation

enum QuoteKind: Sendable {
    case none
    case single
    case double
}

struct ShellWordPart: Sendable {
    let text: String
    let quote: QuoteKind
}

struct ShellWord: Sendable {
    let parts: [ShellWordPart]

    var rawValue: String {
        parts.map(\ .text).joined()
    }

    var hasUnquotedWildcard: Bool {
        parts.contains { part in
            part.quote == .none && PathUtils.containsGlob(part.text)
        }
    }
}

enum LexToken: Sendable {
    case word(ShellWord)
    case pipe
    case andIf
    case orIf
    case semicolon
    case background
    case redirOut
    case redirAppend
    case redirIn
    case redirErrOut
    case redirErrAppend
    case redirErrToOut
    case redirAllOut
    case redirAllAppend
}

enum ShellLexer {
    static func tokenize(_ input: String) throws -> [LexToken] {
        var tokens: [LexToken] = []
        var i = input.startIndex

        var parts: [ShellWordPart] = []
        var currentPart = ""
        var currentQuote: QuoteKind = .none

        func flushPart() {
            guard !currentPart.isEmpty else { return }
            parts.append(ShellWordPart(text: currentPart, quote: currentQuote))
            currentPart = ""
        }

        func flushWord() {
            flushPart()
            guard !parts.isEmpty else { return }
            tokens.append(.word(ShellWord(parts: parts)))
            parts.removeAll(keepingCapacity: true)
        }

        func emitSequenceSeparatorIfNeeded() {
            guard let last = tokens.last else { return }
            switch last {
            case .word:
                tokens.append(.semicolon)
            case .pipe, .andIf, .orIf, .semicolon, .background,
                 .redirOut, .redirAppend, .redirIn, .redirErrOut, .redirErrAppend,
                 .redirErrToOut, .redirAllOut, .redirAllAppend:
                break
            }
        }

        while i < input.endIndex {
            let char = input[i]

            if currentQuote == .none, char == "#" && parts.isEmpty && currentPart.isEmpty {
                while i < input.endIndex, input[i] != "\n" {
                    i = input.index(after: i)
                }
                continue
            }

            if currentQuote == .none, char == "\n" {
                flushWord()
                emitSequenceSeparatorIfNeeded()
                i = input.index(after: i)
                continue
            }

            if currentQuote == .none,
               let opToken = try readOperator(input: input, index: &i, currentWordIsEmpty: parts.isEmpty && currentPart.isEmpty) {
                flushWord()
                tokens.append(opToken)
                continue
            }

            if currentQuote == .none, char.isWhitespace, char != "\n" {
                flushWord()
                i = input.index(after: i)
                continue
            }

            if char == "'", currentQuote != .double {
                if currentQuote == .single {
                    flushPart()
                    currentQuote = .none
                } else {
                    flushPart()
                    currentQuote = .single
                }
                i = input.index(after: i)
                continue
            }

            if char == "\"", currentQuote != .single {
                if currentQuote == .double {
                    flushPart()
                    currentQuote = .none
                } else {
                    flushPart()
                    currentQuote = .double
                }
                i = input.index(after: i)
                continue
            }

            if char == "\\", currentQuote != .single {
                let next = input.index(after: i)
                if next < input.endIndex {
                    currentPart.append(input[next])
                    i = input.index(after: next)
                } else {
                    currentPart.append("\\")
                    i = next
                }
                continue
            }

            currentPart.append(char)
            i = input.index(after: i)
        }

        if currentQuote != .none {
            throw ShellError.parserError("unterminated quote")
        }

        flushWord()
        return tokens
    }

    private static func readOperator(
        input: String,
        index: inout String.Index,
        currentWordIsEmpty: Bool
    ) throws -> LexToken? {
        let tail = input[index...]

        if currentWordIsEmpty, tail.hasPrefix("2>&1") {
            index = input.index(index, offsetBy: 4)
            return .redirErrToOut
        }

        if tail.hasPrefix("&>>") {
            index = input.index(index, offsetBy: 3)
            return .redirAllAppend
        }

        if tail.hasPrefix("&>") {
            index = input.index(index, offsetBy: 2)
            return .redirAllOut
        }

        if currentWordIsEmpty, tail.hasPrefix("2>>") {
            index = input.index(index, offsetBy: 3)
            return .redirErrAppend
        }

        if currentWordIsEmpty, tail.hasPrefix("2>") {
            index = input.index(index, offsetBy: 2)
            return .redirErrOut
        }

        if currentWordIsEmpty, tail.hasPrefix("1>>") {
            index = input.index(index, offsetBy: 3)
            return .redirAppend
        }

        if currentWordIsEmpty, tail.hasPrefix("1>") {
            index = input.index(index, offsetBy: 2)
            return .redirOut
        }

        if tail.hasPrefix(">>") {
            index = input.index(index, offsetBy: 2)
            return .redirAppend
        }

        if tail.hasPrefix("&&") {
            index = input.index(index, offsetBy: 2)
            return .andIf
        }

        if tail.hasPrefix("||") {
            index = input.index(index, offsetBy: 2)
            return .orIf
        }

        let char = input[index]
        switch char {
        case "|":
            index = input.index(after: index)
            return .pipe
        case ";":
            index = input.index(after: index)
            return .semicolon
        case "&":
            index = input.index(after: index)
            return .background
        case ">":
            index = input.index(after: index)
            return .redirOut
        case "<":
            index = input.index(after: index)
            return .redirIn
        default:
            return nil
        }
    }
}
