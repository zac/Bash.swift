import Foundation

extension BashSession {
    struct CommandSubstitutionOutcome {
        var commandLine: String
        var stderr: Data
        var error: ShellError?
        var failure: ExecutionFailure?
    }

    struct PendingHereDocument {
        var delimiter: String
        var stripsLeadingTabs: Bool
    }

    struct FunctionDefinitionParseOutcome {
        var remaining: String
        var error: ShellError?
    }

    func expandCommandSubstitutions(in commandLine: String) async -> CommandSubstitutionOutcome {
        if let failure = await executionControlStore?.checkpoint() {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: Data("\(failure.message)\n".utf8),
                error: nil,
                failure: failure
            )
        }

        var output = ""
        var stderr = Data()
        var quote: QuoteKind = .none
        var index = commandLine.startIndex
        var pendingHereDocuments: [PendingHereDocument] = []

        while index < commandLine.endIndex {
            if let failure = await executionControlStore?.checkpoint() {
                return CommandSubstitutionOutcome(
                    commandLine: output,
                    stderr: Data("\(failure.message)\n".utf8),
                    error: nil,
                    failure: failure
                )
            }

            let character = commandLine[index]

            if character == "\\", quote != .single {
                let next = commandLine.index(after: index)
                output.append(character)
                if next < commandLine.endIndex {
                    output.append(commandLine[next])
                    index = commandLine.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                output.append(character)
                index = commandLine.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                output.append(character)
                index = commandLine.index(after: index)
                continue
            }

            if quote == .none,
               commandLine[index...].hasPrefix("<<"),
               let hereDocument = Self.captureHereDocumentDeclaration(in: commandLine, from: index) {
                output.append(contentsOf: commandLine[index..<hereDocument.endIndex])
                pendingHereDocuments.append(
                    PendingHereDocument(
                        delimiter: hereDocument.delimiter,
                        stripsLeadingTabs: hereDocument.stripsLeadingTabs
                    )
                )
                index = hereDocument.endIndex
                continue
            }

            if character == "\n" {
                output.append(character)
                index = commandLine.index(after: index)

                if !pendingHereDocuments.isEmpty {
                    do {
                        let capture = try Self.captureHereDocumentBodiesVerbatim(
                            in: commandLine,
                            from: index,
                            hereDocuments: pendingHereDocuments
                        )
                        output.append(contentsOf: capture.raw)
                        index = capture.endIndex
                        pendingHereDocuments.removeAll(keepingCapacity: true)
                    } catch let shellError as ShellError {
                        return CommandSubstitutionOutcome(
                            commandLine: output,
                            stderr: stderr,
                            error: shellError
                        )
                    } catch {
                        return CommandSubstitutionOutcome(
                            commandLine: output,
                            stderr: stderr,
                            error: .parserError("\(error)")
                        )
                    }
                }
                continue
            }

            if quote != .single, character == "$" {
                if let arithmetic = Self.captureArithmeticExpansion(in: commandLine, from: index) {
                    output.append(arithmetic.raw)
                    index = arithmetic.endIndex
                    continue
                }

                let next = commandLine.index(after: index)
                if next < commandLine.endIndex, commandLine[next] == "(" {
                    do {
                        let capture = try Self.captureCommandSubstitution(in: commandLine, from: index)
                        let evaluated = await evaluateCommandSubstitution(capture.content)
                        output.append(evaluated.commandLine)
                        stderr.append(evaluated.stderr)
                        if let error = evaluated.error {
                            return CommandSubstitutionOutcome(commandLine: output, stderr: stderr, error: error)
                        }
                        index = capture.endIndex
                        continue
                    } catch let shellError as ShellError {
                        return CommandSubstitutionOutcome(
                            commandLine: output,
                            stderr: stderr,
                            error: shellError
                        )
                    } catch {
                        return CommandSubstitutionOutcome(
                            commandLine: output,
                            stderr: stderr,
                            error: .parserError("\(error)")
                        )
                    }
                }
            }

            output.append(character)
            index = commandLine.index(after: index)
        }

        return CommandSubstitutionOutcome(
            commandLine: output,
            stderr: stderr,
            error: nil,
            failure: nil
        )
    }

    private func evaluateCommandSubstitution(_ command: String) async -> CommandSubstitutionOutcome {
        if let failure = await executionControlStore?.pushCommandSubstitution() {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: Data("\(failure.message)\n".utf8),
                error: nil,
                failure: failure
            )
        }

        let nested = await expandCommandSubstitutions(in: command)
        await executionControlStore?.popCommandSubstitution()
        if let failure = nested.failure {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: nil,
                failure: failure
            )
        }
        if let error = nested.error {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: error,
                failure: nil
            )
        }

        let parsed: ParsedLine
        do {
            parsed = try ShellParser.parse(nested.commandLine)
        } catch let shellError as ShellError {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: shellError,
                failure: nil
            )
        } catch {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: .parserError("\(error)"),
                failure: nil
            )
        }

        let execution = await executeParsedLine(
            parsedLine: parsed,
            stdin: Data(),
            currentDirectory: currentDirectoryStore,
            environment: environmentStore,
            shellFunctions: shellFunctionStore,
            jobControl: nil
        )

        var stderr = nested.stderr
        stderr.append(execution.result.stderr)

        let replacement = Self.trimmingTrailingNewlines(
            from: execution.result.stdoutString
        )
        return CommandSubstitutionOutcome(
            commandLine: replacement,
            stderr: stderr,
            error: nil,
            failure: nil
        )
    }

    func parseAndRegisterFunctionDefinitions(
        in commandLine: String
    ) -> FunctionDefinitionParseOutcome {
        var functionStore = shellFunctionStore
        var parsed = Self.parseFunctionDefinitions(
            in: commandLine,
            functionStore: &functionStore
        )

        if parsed.error == nil,
           parsed.remaining == commandLine,
           let marker = Self.findDelimitedKeyword(
               "function",
               in: commandLine,
               from: commandLine.startIndex
           ) {
            let prefix = String(commandLine[..<marker.separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(commandLine[marker.keywordIndex...])

            var tailStore = functionStore
            let tailParsed = Self.parseFunctionDefinitions(
                in: tail,
                functionStore: &tailStore
            )

            if let error = tailParsed.error {
                return FunctionDefinitionParseOutcome(
                    remaining: commandLine,
                    error: error
                )
            }

            functionStore = tailStore
            let tailRemaining = tailParsed.remaining
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if prefix.isEmpty {
                parsed.remaining = tailRemaining
            } else if tailRemaining.isEmpty {
                parsed.remaining = prefix
            } else {
                parsed.remaining = "\(prefix); \(tailRemaining)"
            }
        }

        if parsed.error == nil {
            shellFunctionStore = functionStore
        }
        return parsed
    }

    static func captureCommandSubstitution(
        in commandLine: String,
        from dollarIndex: String.Index
    ) throws -> (content: String, endIndex: String.Index) {
        let openIndex = commandLine.index(after: dollarIndex)
        var index = commandLine.index(after: openIndex)
        let contentStart = index
        var depth = 1
        var quote: QuoteKind = .none

        while index < commandLine.endIndex {
            let character = commandLine[index]

            if character == "\\", quote != .single {
                let next = commandLine.index(after: index)
                if next < commandLine.endIndex {
                    index = commandLine.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = commandLine.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = commandLine.index(after: index)
                continue
            }

            if quote == .none {
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        let content = String(commandLine[contentStart..<index])
                        return (
                            content: content,
                            endIndex: commandLine.index(after: index)
                        )
                    }
                }
            }

            index = commandLine.index(after: index)
        }

        throw ShellError.parserError("unterminated command substitution")
    }

    static func captureArithmeticExpansion(
        in commandLine: String,
        from dollarIndex: String.Index
    ) -> (raw: String, endIndex: String.Index)? {
        let open = commandLine.index(after: dollarIndex)
        guard open < commandLine.endIndex, commandLine[open] == "(" else {
            return nil
        }

        let secondOpen = commandLine.index(after: open)
        guard secondOpen < commandLine.endIndex, commandLine[secondOpen] == "(" else {
            return nil
        }

        var depth = 1
        var cursor = commandLine.index(after: secondOpen)

        while cursor < commandLine.endIndex {
            if commandLine[cursor] == "(" {
                let next = commandLine.index(after: cursor)
                if next < commandLine.endIndex, commandLine[next] == "(" {
                    depth += 1
                    cursor = commandLine.index(after: next)
                    continue
                }
            } else if commandLine[cursor] == ")" {
                let next = commandLine.index(after: cursor)
                if next < commandLine.endIndex, commandLine[next] == ")" {
                    depth -= 1
                    if depth == 0 {
                        let end = commandLine.index(after: next)
                        return (raw: String(commandLine[dollarIndex..<end]), endIndex: end)
                    }
                    cursor = commandLine.index(after: next)
                    continue
                }
            }
            cursor = commandLine.index(after: cursor)
        }

        return nil
    }

    static func captureHereDocumentDeclaration(
        in commandLine: String,
        from operatorIndex: String.Index
    ) -> (delimiter: String, stripsLeadingTabs: Bool, endIndex: String.Index)? {
        let stripsLeadingTabs: Bool
        let indexOffset: Int

        if commandLine[operatorIndex...].hasPrefix("<<-") {
            stripsLeadingTabs = true
            indexOffset = 3
        } else {
            stripsLeadingTabs = false
            indexOffset = 2
        }

        var index = commandLine.index(operatorIndex, offsetBy: indexOffset)

        while index < commandLine.endIndex,
              commandLine[index].isWhitespace,
              commandLine[index] != "\n" {
            index = commandLine.index(after: index)
        }

        guard index < commandLine.endIndex, commandLine[index] != "\n" else {
            return nil
        }

        var delimiter = ""
        var quote: QuoteKind = .none
        var consumedAny = false

        while index < commandLine.endIndex {
            let character = commandLine[index]

            if quote == .none, character.isWhitespace {
                break
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                consumedAny = true
                index = commandLine.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                consumedAny = true
                index = commandLine.index(after: index)
                continue
            }

            if character == "\\", quote != .single {
                let next = commandLine.index(after: index)
                if next < commandLine.endIndex {
                    delimiter.append(commandLine[next])
                    index = commandLine.index(after: next)
                } else {
                    delimiter.append(character)
                    index = next
                }
                consumedAny = true
                continue
            }

            delimiter.append(character)
            consumedAny = true
            index = commandLine.index(after: index)
        }

        guard consumedAny, quote == .none else {
            return nil
        }

        return (delimiter: delimiter, stripsLeadingTabs: stripsLeadingTabs, endIndex: index)
    }

    static func captureHereDocumentBodiesVerbatim(
        in commandLine: String,
        from startIndex: String.Index,
        hereDocuments: [PendingHereDocument]
    ) throws -> (raw: String, endIndex: String.Index) {
        var raw = ""
        var index = startIndex

        for hereDocument in hereDocuments {
            var matched = false

            while index < commandLine.endIndex {
                let lineStart = index
                while index < commandLine.endIndex, commandLine[index] != "\n" {
                    index = commandLine.index(after: index)
                }

                let line = String(commandLine[lineStart..<index])
                let comparisonSource = hereDocument.stripsLeadingTabs
                    ? Self.stripLeadingTabs(from: line)
                    : line
                let comparisonLine = comparisonSource.hasSuffix("\r")
                    ? String(comparisonSource.dropLast())
                    : comparisonSource

                raw.append(contentsOf: line)
                if index < commandLine.endIndex {
                    raw.append("\n")
                    index = commandLine.index(after: index)
                }

                if comparisonLine == hereDocument.delimiter {
                    matched = true
                    break
                }
            }

            if !matched {
                throw ShellError.parserError("unterminated here-document")
            }
        }

        return (raw: raw, endIndex: index)
    }

    static func stripLeadingTabs(from line: String) -> String {
        String(line.drop { $0 == "\t" })
    }

    static func parseFunctionDefinitions(
        in commandLine: String,
        functionStore: inout [String: String]
    ) -> FunctionDefinitionParseOutcome {
        var index = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &index)
        var parsedAny = false

        while index < commandLine.endIndex {
            let definitionStart = index

            let hasFunctionKeyword: Bool
            let functionName: String

            if Self.consumeKeyword("function", in: commandLine, index: &index) {
                hasFunctionKeyword = true
                Self.skipWhitespace(in: commandLine, index: &index)
                guard let parsedName = Self.readIdentifier(in: commandLine, index: &index) else {
                    return FunctionDefinitionParseOutcome(
                        remaining: commandLine,
                        error: .parserError("function: expected function name")
                    )
                }
                functionName = parsedName
            } else {
                hasFunctionKeyword = false
                guard let parsedName = Self.readIdentifier(in: commandLine, index: &index) else {
                    let remaining = String(commandLine[definitionStart...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return FunctionDefinitionParseOutcome(
                        remaining: parsedAny ? remaining : commandLine,
                        error: nil
                    )
                }
                functionName = parsedName
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            var hasParenthesizedSignature = false
            if Self.consumeLiteral("(", in: commandLine, index: &index) {
                hasParenthesizedSignature = true
                Self.skipWhitespace(in: commandLine, index: &index)
                guard Self.consumeLiteral(")", in: commandLine, index: &index) else {
                    if hasFunctionKeyword {
                        return FunctionDefinitionParseOutcome(
                            remaining: commandLine,
                            error: .parserError("function \(functionName): expected ')'"))
                    }

                    let remaining = String(commandLine[definitionStart...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return FunctionDefinitionParseOutcome(
                        remaining: parsedAny ? remaining : commandLine,
                        error: nil
                    )
                }
                Self.skipWhitespace(in: commandLine, index: &index)
            } else if !hasFunctionKeyword {
                let remaining = String(commandLine[definitionStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return FunctionDefinitionParseOutcome(
                    remaining: parsedAny ? remaining : commandLine,
                    error: nil
                )
            }

            guard index < commandLine.endIndex, commandLine[index] == "{" else {
                if hasFunctionKeyword || hasParenthesizedSignature {
                    return FunctionDefinitionParseOutcome(
                        remaining: commandLine,
                        error: .parserError("function \(functionName): expected '{'"))
                }

                let remaining = String(commandLine[definitionStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return FunctionDefinitionParseOutcome(
                    remaining: parsedAny ? remaining : commandLine,
                    error: nil
                )
            }

            do {
                let braceCapture = try captureBalancedBraces(
                    in: commandLine,
                    from: index
                )
                let body = String(commandLine[braceCapture.contentRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                functionStore[functionName] = body
                parsedAny = true
                index = braceCapture.endIndex
            } catch let shellError as ShellError {
                return FunctionDefinitionParseOutcome(
                    remaining: commandLine,
                    error: shellError
                )
            } catch {
                return FunctionDefinitionParseOutcome(
                    remaining: commandLine,
                    error: .parserError("\(error)")
                )
            }

            let boundary = index
            Self.skipWhitespace(in: commandLine, index: &index)
            if index == commandLine.endIndex {
                return FunctionDefinitionParseOutcome(
                    remaining: "",
                    error: nil
                )
            }

            if commandLine[index] == ";" {
                index = commandLine.index(after: index)
                Self.skipWhitespace(in: commandLine, index: &index)
                if index == commandLine.endIndex {
                    return FunctionDefinitionParseOutcome(
                        remaining: "",
                        error: nil
                    )
                }
                continue
            }

            let remaining = String(commandLine[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FunctionDefinitionParseOutcome(
                remaining: remaining,
                error: nil
            )
        }

        return FunctionDefinitionParseOutcome(
            remaining: parsedAny ? "" : commandLine,
            error: nil
        )
    }

    static func captureBalancedBraces(
        in commandLine: String,
        from openBraceIndex: String.Index
    ) throws -> (contentRange: Range<String.Index>, endIndex: String.Index) {
        var index = commandLine.index(after: openBraceIndex)
        let contentStart = index
        var depth = 1
        var quote: QuoteKind = .none

        while index < commandLine.endIndex {
            let character = commandLine[index]

            if character == "\\", quote != .single {
                let next = commandLine.index(after: index)
                if next < commandLine.endIndex {
                    index = commandLine.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = commandLine.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = commandLine.index(after: index)
                continue
            }

            if quote == .none {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (
                            contentRange: contentStart..<index,
                            endIndex: commandLine.index(after: index)
                        )
                    }
                }
            }

            index = commandLine.index(after: index)
        }

        throw ShellError.parserError("unterminated function body")
    }

    static func trimmingTrailingNewlines(from value: String) -> String {
        var output = value
        while output.hasSuffix("\n") {
            output.removeLast()
        }
        return output
    }

    static func expandWord(
        _ word: ShellWord,
        environment: [String: String]
    ) -> String {
        var output = ""
        for part in word.parts {
            switch part.quote {
            case .single:
                output.append(part.text)
            case .none, .double:
                output.append(expandVariables(in: part.text, environment: environment))
            }
        }
        return output
    }

    static func expandVariables(
        in string: String,
        environment: [String: String]
    ) -> String {
        var result = ""
        var index = string.startIndex

        func readIdentifier(startingAt start: String.Index) -> (String, String.Index) {
            var cursor = start
            var value = ""
            while cursor < string.endIndex {
                let character = string[cursor]
                if character.isLetter || character.isNumber || character == "_" {
                    value.append(character)
                    cursor = string.index(after: cursor)
                } else {
                    break
                }
            }
            return (value, cursor)
        }

        while index < string.endIndex {
            let character = string[index]
            guard character == "$" else {
                result.append(character)
                index = string.index(after: index)
                continue
            }

            let next = string.index(after: index)
            guard next < string.endIndex else {
                result.append("$")
                break
            }

            if string[next] == "!" {
                result += environment["!"] ?? ""
                index = string.index(after: next)
                continue
            }

            if string[next] == "@" || string[next] == "*" || string[next] == "#" {
                result += environment[String(string[next])] ?? ""
                index = string.index(after: next)
                continue
            }

            if string[next] == "{" {
                guard let close = string[next...].firstIndex(of: "}") else {
                    result.append("$")
                    index = next
                    continue
                }

                let contentStart = string.index(after: next)
                let content = String(string[contentStart..<close])
                if let fallbackRange = content.range(of: ":-") {
                    let key = String(content[..<fallbackRange.lowerBound])
                    let fallback = String(content[fallbackRange.upperBound...])
                    let resolved = environment[key]
                    if let resolved, !resolved.isEmpty {
                        result += resolved
                    } else {
                        result += fallback
                    }
                } else {
                    result += environment[content] ?? ""
                }
                index = string.index(after: close)
                continue
            }

            let (name, endIndex) = readIdentifier(startingAt: next)
            if name.isEmpty {
                result.append("$")
                index = next
            } else {
                result += environment[name] ?? ""
                index = endIndex
            }
        }

        return result
    }
}
