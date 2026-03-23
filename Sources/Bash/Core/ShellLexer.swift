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
            part.quote == .none && WorkspacePath.containsGlob(part.text)
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
    case redirHereDoc(HereDocument)
}

enum ShellLexer {
    static func tokenize(_ input: String) throws -> [LexToken] {
        var tokens: [LexToken] = []
        var i = input.startIndex

        var parts: [ShellWordPart] = []
        var currentPart = ""
        var currentQuote: QuoteKind = .none
        var expectingHereDocumentDelimiter = false
        var pendingHereDocumentStripsLeadingTabs = false
        var pendingHereDocumentTokenIndexes: [Int] = []

        func flushPart() {
            guard !currentPart.isEmpty else { return }
            parts.append(ShellWordPart(text: currentPart, quote: currentQuote))
            currentPart = ""
        }

        func flushWord() {
            flushPart()
            guard !parts.isEmpty else { return }
            let word = ShellWord(parts: parts)
            if expectingHereDocumentDelimiter {
                let hereDocument = HereDocument(
                    delimiter: word.rawValue,
                    body: "",
                    allowsExpansion: word.parts.allSatisfy { $0.quote == .none },
                    stripsLeadingTabs: pendingHereDocumentStripsLeadingTabs
                )
                pendingHereDocumentTokenIndexes.append(tokens.count)
                tokens.append(.redirHereDoc(hereDocument))
                expectingHereDocumentDelimiter = false
                pendingHereDocumentStripsLeadingTabs = false
            } else {
                tokens.append(.word(word))
            }
            parts.removeAll(keepingCapacity: true)
        }

        func emitSequenceSeparatorIfNeeded() {
            guard let last = tokens.last else { return }
            switch last {
            case .word:
                tokens.append(.semicolon)
            case .pipe, .andIf, .orIf, .semicolon, .background,
                 .redirOut, .redirAppend, .redirIn, .redirErrOut, .redirErrAppend,
                 .redirErrToOut, .redirAllOut, .redirAllAppend, .redirHereDoc:
                break
            }
        }

        func emitSequenceSeparatorAfterHereDocumentsIfNeeded() {
            guard i < input.endIndex, let last = tokens.last else { return }
            switch last {
            case .pipe, .andIf, .orIf, .semicolon, .background:
                break
            case .word, .redirOut, .redirAppend, .redirIn, .redirErrOut, .redirErrAppend,
                 .redirErrToOut, .redirAllOut, .redirAllAppend, .redirHereDoc:
                tokens.append(.semicolon)
            }
        }

        func capturePendingHereDocuments() throws {
            for tokenIndex in pendingHereDocumentTokenIndexes {
                guard case let .redirHereDoc(hereDocument) = tokens[tokenIndex] else {
                    continue
                }

                let body = try readHereDocumentBody(
                    input: input,
                    index: &i,
                    delimiter: hereDocument.delimiter,
                    stripsLeadingTabs: hereDocument.stripsLeadingTabs
                )
                tokens[tokenIndex] = .redirHereDoc(
                    HereDocument(
                        delimiter: hereDocument.delimiter,
                        body: body,
                        allowsExpansion: hereDocument.allowsExpansion,
                        stripsLeadingTabs: hereDocument.stripsLeadingTabs
                    )
                )
            }
            pendingHereDocumentTokenIndexes.removeAll(keepingCapacity: true)
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
                if expectingHereDocumentDelimiter {
                    throw ShellError.parserError("missing redirection target")
                }
                i = input.index(after: i)
                if !pendingHereDocumentTokenIndexes.isEmpty {
                    try capturePendingHereDocuments()
                    emitSequenceSeparatorAfterHereDocumentsIfNeeded()
                } else {
                    emitSequenceSeparatorIfNeeded()
                }
                continue
            }

            if currentQuote == .none, input[i...].hasPrefix("<<-") {
                flushWord()
                expectingHereDocumentDelimiter = true
                pendingHereDocumentStripsLeadingTabs = true
                i = input.index(i, offsetBy: 3)
                continue
            }

            if currentQuote == .none, input[i...].hasPrefix("<<") {
                flushWord()
                expectingHereDocumentDelimiter = true
                pendingHereDocumentStripsLeadingTabs = false
                i = input.index(i, offsetBy: 2)
                continue
            }

            if currentQuote == .none,
               let opToken = try readOperator(input: input, index: &i, currentWordIsEmpty: parts.isEmpty && currentPart.isEmpty) {
                flushWord()
                tokens.append(opToken)
                continue
            }

            if currentQuote != .single,
               char == "$",
               let expansion = captureArithmeticExpansion(in: input, from: i) {
                currentPart.append(expansion.raw)
                i = expansion.endIndex
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
        if expectingHereDocumentDelimiter {
            throw ShellError.parserError("missing redirection target")
        }
        if !pendingHereDocumentTokenIndexes.isEmpty {
            throw ShellError.parserError("unterminated here-document")
        }
        return tokens
    }

    private static func readHereDocumentBody(
        input: String,
        index: inout String.Index,
        delimiter: String,
        stripsLeadingTabs: Bool
    ) throws -> String {
        var body = ""

        while index < input.endIndex {
            let lineStart = index
            while index < input.endIndex, input[index] != "\n" {
                index = input.index(after: index)
            }

            let line = String(input[lineStart..<index])
            let contentLine = stripsLeadingTabs ? stripLeadingTabs(from: line) : line
            let comparisonLine: String
            if contentLine.hasSuffix("\r") {
                comparisonLine = String(contentLine.dropLast())
            } else {
                comparisonLine = contentLine
            }

            if comparisonLine == delimiter {
                if index < input.endIndex {
                    index = input.index(after: index)
                }
                return body
            }

            body.append(contentsOf: contentLine)
            if index < input.endIndex {
                body.append("\n")
                index = input.index(after: index)
            }
        }

        throw ShellError.parserError("unterminated here-document")
    }

    private static func stripLeadingTabs(from line: String) -> String {
        String(line.drop { $0 == "\t" })
    }

    private static func captureArithmeticExpansion(
        in input: String,
        from dollarIndex: String.Index
    ) -> (raw: String, endIndex: String.Index)? {
        let open = input.index(after: dollarIndex)
        guard open < input.endIndex, input[open] == "(" else {
            return nil
        }

        let secondOpen = input.index(after: open)
        guard secondOpen < input.endIndex, input[secondOpen] == "(" else {
            return nil
        }

        var depth = 1
        var cursor = input.index(after: secondOpen)

        while cursor < input.endIndex {
            if input[cursor] == "(" {
                let next = input.index(after: cursor)
                if next < input.endIndex, input[next] == "(" {
                    depth += 1
                    cursor = input.index(after: next)
                    continue
                }
            } else if input[cursor] == ")" {
                let next = input.index(after: cursor)
                if next < input.endIndex, input[next] == ")" {
                    depth -= 1
                    if depth == 0 {
                        let end = input.index(after: next)
                        return (raw: String(input[dollarIndex..<end]), endIndex: end)
                    }
                    cursor = input.index(after: next)
                    continue
                }
            }
            cursor = input.index(after: cursor)
        }

        return nil
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
