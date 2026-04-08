import Foundation
import BashCore

extension BashSession {
    struct SimpleForLoop {
        enum Kind {
            case list(variableName: String, values: [String])
            case cStyle(initializer: String, condition: String, increment: String)
        }

        var kind: Kind
        var body: String
        var trailingAction: TrailingAction
    }

    enum SimpleForLoopParseResult {
        case notForLoop
        case success(SimpleForLoop)
        case failure(ShellError)
    }

    struct IfBranch {
        var condition: String
        var body: String
    }

    struct SimpleIfBlock {
        var branches: [IfBranch]
        var elseBody: String?
        var trailingAction: TrailingAction
    }

    enum SimpleIfBlockParseResult {
        case notIfBlock
        case success(SimpleIfBlock)
        case failure(ShellError)
    }

    struct SimpleWhileLoop {
        var leadingCommands: String?
        var condition: String
        var isUntil: Bool
        var body: String
        var trailingAction: TrailingAction
    }

    enum SimpleWhileLoopParseResult {
        case notWhileLoop
        case success(SimpleWhileLoop)
        case failure(ShellError)
    }

    struct SimpleCaseArm {
        var patterns: [String]
        var body: String
    }

    struct SimpleCaseBlock {
        var leadingCommands: String?
        var subject: String
        var arms: [SimpleCaseArm]
        var trailingAction: TrailingAction
    }

    enum SimpleCaseBlockParseResult {
        case notCaseBlock
        case success(SimpleCaseBlock)
        case failure(ShellError)
    }

    func executeSimpleForLoopIfPresent(
        commandLine: String,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        let parsedLoop = parseSimpleForLoop(commandLine)
        switch parsedLoop {
        case .notForLoop:
            return nil
        case let .failure(error):
            var stderr = prefixedStderr
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
        case let .success(loop):
            let parsedBody: ParsedLine
            do {
                parsedBody = try ShellParser.parse(loop.body)
            } catch {
                var stderr = prefixedStderr
                stderr.append(Data("\(error)\n".utf8))
                return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
            }

            var combinedOut = Data()
            var combinedErr = Data()
            var lastExitCode: Int32 = 0

            switch loop.kind {
            case let .list(variableName, values):
                for (offset, value) in values.enumerated() {
                    if let failure = await executionControlStore?.recordLoopIteration(
                        loopName: "for",
                        iteration: offset + 1
                    ) {
                        combinedErr.append(Data("\(failure.message)\n".utf8))
                        lastExitCode = failure.exitCode
                        break
                    }

                    environmentStore[variableName] = value
                    let execution = await executeParsedLine(
                        parsedLine: parsedBody,
                        stdin: stdin,
                        currentDirectory: currentDirectoryStore,
                        environment: environmentStore,
                        shellFunctions: shellFunctionStore,
                        jobControl: jobManager
                    )

                    currentDirectoryStore = execution.currentDirectory
                    environmentStore = execution.environment
                    environmentStore["PWD"] = currentDirectoryStore

                    combinedOut.append(execution.result.stdout)
                    combinedErr.append(execution.result.stderr)
                    lastExitCode = execution.result.exitCode
                }
            case let .cStyle(initializer, condition, increment):
                if let initializerError = executeCStyleArithmeticStatement(initializer) {
                    var stderr = prefixedStderr
                    stderr.append(Data("\(initializerError)\n".utf8))
                    return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
                }

                var iterations = 0
                while true {
                    iterations += 1
                    if let failure = await executionControlStore?.recordLoopIteration(
                        loopName: "for",
                        iteration: iterations
                    ) {
                        combinedErr.append(Data("\(failure.message)\n".utf8))
                        lastExitCode = failure.exitCode
                        break
                    }

                    let shouldContinue: Bool
                    if condition.isEmpty {
                        shouldContinue = true
                    } else {
                        let evaluated = ArithmeticEvaluator.evaluate(
                            condition,
                            environment: environmentStore
                        ) ?? 0
                        shouldContinue = evaluated != 0
                    }

                    if !shouldContinue {
                        break
                    }

                    let execution = await executeParsedLine(
                        parsedLine: parsedBody,
                        stdin: stdin,
                        currentDirectory: currentDirectoryStore,
                        environment: environmentStore,
                        shellFunctions: shellFunctionStore,
                        jobControl: jobManager
                    )

                    currentDirectoryStore = execution.currentDirectory
                    environmentStore = execution.environment
                    environmentStore["PWD"] = currentDirectoryStore

                    combinedOut.append(execution.result.stdout)
                    combinedErr.append(execution.result.stderr)
                    lastExitCode = execution.result.exitCode

                    if let incrementError = executeCStyleArithmeticStatement(increment) {
                        combinedErr.append(Data("\(incrementError)\n".utf8))
                        lastExitCode = 2
                        break
                    }
                }
            }

            var result = CommandResult(
                stdout: combinedOut,
                stderr: combinedErr,
                exitCode: lastExitCode
            )
            await applyTrailingAction(loop.trailingAction, to: &result)
            mergePrefixedStderr(prefixedStderr, into: &result)

            return result
        }
    }

    func parseSimpleForLoop(_ commandLine: String) -> SimpleForLoopParseResult {
        var index = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &index)

        guard Self.consumeKeyword(
            "for",
            in: commandLine,
            index: &index
        ) else {
            return .notForLoop
        }

        Self.skipWhitespace(in: commandLine, index: &index)
        let loopKind: SimpleForLoop.Kind

        if commandLine[index...].hasPrefix("((") {
            guard let cStyle = Self.parseCStyleForHeader(commandLine, index: &index) else {
                return .failure(.parserError("for: expected C-style header '((init;cond;inc))'"))
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            guard let doMarker = Self.findDelimitedKeyword(
                "do",
                in: commandLine,
                from: index
            ) else {
                return .failure(.parserError("for: expected 'do'"))
            }

            index = doMarker.afterKeywordIndex
            loopKind = .cStyle(
                initializer: cStyle.initializer,
                condition: cStyle.condition,
                increment: cStyle.increment
            )
        } else {
            guard let variableName = Self.readIdentifier(in: commandLine, index: &index) else {
                return .failure(.parserError("for: expected loop variable"))
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            guard Self.consumeKeyword("in", in: commandLine, index: &index) else {
                return .failure(.parserError("for: expected 'in'"))
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            guard let valuesMarker = Self.findDelimitedKeyword(
                "do",
                in: commandLine,
                from: index
            ) else {
                return .failure(.parserError("for: expected 'do'"))
            }

            let rawValues = String(commandLine[index..<valuesMarker.separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let values: [String]
            if rawValues.isEmpty {
                values = []
            } else {
                do {
                    values = try Self.parseLoopValues(
                        rawValues,
                        environment: environmentStore
                    )
                } catch let shellError as ShellError {
                    return .failure(shellError)
                } catch {
                    return .failure(.parserError("\(error)"))
                }
            }

            index = valuesMarker.afterKeywordIndex
            loopKind = .list(variableName: variableName, values: values)
        }

        let bodyStart = index
        guard let bodyMarker = Self.findDelimitedKeyword(
            "done",
            in: commandLine,
            from: bodyStart
        ) else {
            return .failure(.parserError("for: expected 'done'"))
        }

        let body = String(commandLine[bodyStart..<bodyMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return .failure(.parserError("for: expected non-empty loop body"))
        }

        let tail = String(commandLine[bodyMarker.afterKeywordIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingAction: TrailingAction
        switch Self.parseTrailingAction(from: tail, context: "for") {
        case let .success(action):
            trailingAction = action
        case let .failure(error):
            return .failure(error)
        }

        return .success(
            SimpleForLoop(
                kind: loopKind,
                body: body,
                trailingAction: trailingAction
            )
        )
    }

    func executeSimpleIfBlockIfPresent(
        commandLine: String,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        let parsedIf = parseSimpleIfBlock(commandLine)
        switch parsedIf {
        case .notIfBlock:
            return nil
        case let .failure(error):
            var stderr = prefixedStderr
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
        case let .success(ifBlock):
            var combinedOut = Data()
            var combinedErr = Data()
            var lastExitCode: Int32 = 0

            var selectedBody: String?
            for branch in ifBlock.branches {
                let conditionResult = await executeConditionalExpression(
                    branch.condition,
                    stdin: stdin
                )
                combinedOut.append(conditionResult.stdout)
                combinedErr.append(conditionResult.stderr)
                lastExitCode = conditionResult.exitCode

                if conditionResult.exitCode == 0 {
                    selectedBody = branch.body
                    break
                }
            }

            if selectedBody == nil {
                selectedBody = ifBlock.elseBody
                if selectedBody == nil {
                    lastExitCode = 0
                }
            }

            if let selectedBody, !selectedBody.isEmpty {
                let bodyResult = await executeStandardCommandLine(
                    selectedBody,
                    stdin: stdin
                )
                combinedOut.append(bodyResult.stdout)
                combinedErr.append(bodyResult.stderr)
                lastExitCode = bodyResult.exitCode
            }

            var result = CommandResult(
                stdout: combinedOut,
                stderr: combinedErr,
                exitCode: lastExitCode
            )
            await applyTrailingAction(ifBlock.trailingAction, to: &result)
            mergePrefixedStderr(prefixedStderr, into: &result)
            return result
        }
    }

    func parseSimpleIfBlock(_ commandLine: String) -> SimpleIfBlockParseResult {
        var index = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &index)

        guard Self.consumeKeyword("if", in: commandLine, index: &index) else {
            return .notIfBlock
        }

        Self.skipWhitespace(in: commandLine, index: &index)
        guard let thenMarker = Self.findDelimitedKeyword(
            "then",
            in: commandLine,
            from: index
        ) else {
            return .failure(.parserError("if: expected 'then'"))
        }

        let condition = String(commandLine[index..<thenMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if condition.isEmpty {
            return .failure(.parserError("if: expected condition command"))
        }

        var branches: [IfBranch] = []
        var currentCondition = condition
        var bodyStart = thenMarker.afterKeywordIndex

        while true {
            guard let marker = Self.findFirstDelimitedKeyword(
                ["elif", "else", "fi"],
                in: commandLine,
                from: bodyStart
            ) else {
                return .failure(.parserError("if: expected 'fi'"))
            }

            let branchBody = String(commandLine[bodyStart..<marker.match.separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            branches.append(
                IfBranch(
                    condition: currentCondition,
                    body: branchBody
                )
            )

            switch marker.keyword {
            case "elif":
                var elifConditionStart = marker.match.afterKeywordIndex
                Self.skipWhitespace(in: commandLine, index: &elifConditionStart)
                guard let elifThenMarker = Self.findDelimitedKeyword(
                    "then",
                    in: commandLine,
                    from: elifConditionStart
                ) else {
                    return .failure(.parserError("if: expected 'then' after 'elif'"))
                }

                let elifCondition = String(commandLine[elifConditionStart..<elifThenMarker.separatorIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if elifCondition.isEmpty {
                    return .failure(.parserError("if: expected condition command"))
                }
                currentCondition = elifCondition
                bodyStart = elifThenMarker.afterKeywordIndex
                continue

            case "else":
                let elseStart = marker.match.afterKeywordIndex
                guard let fiMarker = Self.findDelimitedKeyword(
                    "fi",
                    in: commandLine,
                    from: elseStart
                ) else {
                    return .failure(.parserError("if: expected 'fi'"))
                }

                let elseBody = String(commandLine[elseStart..<fiMarker.separatorIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(commandLine[fiMarker.afterKeywordIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let trailingAction: TrailingAction
                switch Self.parseTrailingAction(from: tail, context: "if") {
                case let .success(action):
                    trailingAction = action
                case let .failure(error):
                    return .failure(error)
                }

                return .success(
                    SimpleIfBlock(
                        branches: branches,
                        elseBody: elseBody,
                        trailingAction: trailingAction
                    )
                )

            case "fi":
                let tail = String(commandLine[marker.match.afterKeywordIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trailingAction: TrailingAction
                switch Self.parseTrailingAction(from: tail, context: "if") {
                case let .success(action):
                    trailingAction = action
                case let .failure(error):
                    return .failure(error)
                }

                return .success(
                    SimpleIfBlock(
                        branches: branches,
                        elseBody: nil,
                        trailingAction: trailingAction
                    )
                )
            default:
                return .failure(.parserError("if: unsupported branch keyword"))
            }
        }
    }

    func executeSimpleWhileLoopIfPresent(
        commandLine: String,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        await executeSimpleConditionalLoopIfPresent(
            parseSimpleWhileLoop(commandLine),
            stdin: stdin,
            prefixedStderr: prefixedStderr
        )
    }

    func executeSimpleUntilLoopIfPresent(
        commandLine: String,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        await executeSimpleConditionalLoopIfPresent(
            parseSimpleUntilLoop(commandLine),
            stdin: stdin,
            prefixedStderr: prefixedStderr
        )
    }

    func executeSimpleConditionalLoopIfPresent(
        _ parsedLoop: SimpleWhileLoopParseResult,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        switch parsedLoop {
        case .notWhileLoop:
            return nil
        case let .failure(error):
            var stderr = prefixedStderr
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
        case let .success(loop):
            let parsedBody: ParsedLine
            do {
                parsedBody = try ShellParser.parse(loop.body)
            } catch {
                var stderr = prefixedStderr
                stderr.append(Data("\(error)\n".utf8))
                return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
            }

            var combinedOut = Data()
            var combinedErr = Data()
            var lastExitCode: Int32 = 0
            var didRunBody = false

            if let leadingCommands = loop.leadingCommands,
               !leadingCommands.isEmpty {
                let leadingResult = await executeStandardCommandLine(
                    leadingCommands,
                    stdin: stdin
                )
                combinedOut.append(leadingResult.stdout)
                combinedErr.append(leadingResult.stderr)
                lastExitCode = leadingResult.exitCode
            }

            var iterations = 0
            while true {
                iterations += 1
                let loopName = loop.isUntil ? "until" : "while"
                if let failure = await executionControlStore?.recordLoopIteration(
                    loopName: loopName,
                    iteration: iterations
                ) {
                    combinedErr.append(Data("\(failure.message)\n".utf8))
                    lastExitCode = failure.exitCode
                    break
                }

                let conditionResult = await executeConditionalExpression(
                    loop.condition,
                    stdin: stdin
                )
                combinedOut.append(conditionResult.stdout)
                combinedErr.append(conditionResult.stderr)

                let conditionSucceeded = conditionResult.exitCode == 0
                let shouldRunBody = loop.isUntil ? !conditionSucceeded : conditionSucceeded

                if !shouldRunBody {
                    if !loop.isUntil && conditionResult.exitCode > 1, !didRunBody {
                        lastExitCode = conditionResult.exitCode
                    } else if !didRunBody {
                        lastExitCode = 0
                    }
                    break
                }

                let bodyExecution = await executeParsedLine(
                    parsedLine: parsedBody,
                    stdin: stdin,
                    currentDirectory: currentDirectoryStore,
                    environment: environmentStore,
                    shellFunctions: shellFunctionStore,
                    jobControl: jobManager
                )
                currentDirectoryStore = bodyExecution.currentDirectory
                environmentStore = bodyExecution.environment
                environmentStore["PWD"] = currentDirectoryStore

                combinedOut.append(bodyExecution.result.stdout)
                combinedErr.append(bodyExecution.result.stderr)
                lastExitCode = bodyExecution.result.exitCode
                didRunBody = true
            }

            var result = CommandResult(
                stdout: combinedOut,
                stderr: combinedErr,
                exitCode: lastExitCode
            )
            await applyTrailingAction(loop.trailingAction, to: &result)
            mergePrefixedStderr(prefixedStderr, into: &result)
            return result
        }
    }

    func parseSimpleWhileLoop(_ commandLine: String) -> SimpleWhileLoopParseResult {
        parseSimpleConditionalLoop(
            commandLine,
            keyword: "while",
            isUntil: false
        )
    }

    func parseSimpleUntilLoop(_ commandLine: String) -> SimpleWhileLoopParseResult {
        parseSimpleConditionalLoop(
            commandLine,
            keyword: "until",
            isUntil: true
        )
    }

    func parseSimpleConditionalLoop(
        _ commandLine: String,
        keyword: String,
        isUntil: Bool
    ) -> SimpleWhileLoopParseResult {
        var start = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &start)

        if commandLine[start...].hasPrefix(keyword) {
            return parseConditionalLoopClause(
                String(commandLine[start...]),
                keyword: keyword,
                isUntil: isUntil,
                leadingCommands: nil
            )
        }

        guard let marker = Self.findDelimitedKeyword(
            keyword,
            in: commandLine,
            from: start
        ) else {
            return .notWhileLoop
        }

        let prefix = String(commandLine[start..<marker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            return .notWhileLoop
        }

        return parseConditionalLoopClause(
            String(commandLine[marker.keywordIndex...]),
            keyword: keyword,
            isUntil: isUntil,
            leadingCommands: prefix
        )
    }

    func parseConditionalLoopClause(
        _ loopClause: String,
        keyword: String,
        isUntil: Bool,
        leadingCommands: String?
    ) -> SimpleWhileLoopParseResult {
        var index = loopClause.startIndex
        Self.skipWhitespace(in: loopClause, index: &index)
        guard Self.consumeKeyword(keyword, in: loopClause, index: &index) else {
            return .notWhileLoop
        }

        Self.skipWhitespace(in: loopClause, index: &index)
        guard let doMarker = Self.findDelimitedKeyword(
            "do",
            in: loopClause,
            from: index
        ) else {
            return .failure(.parserError("\(keyword): expected 'do'"))
        }

        let condition = String(loopClause[index..<doMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if condition.isEmpty {
            return .failure(.parserError("\(keyword): expected condition command"))
        }

        let bodyStart = doMarker.afterKeywordIndex
        guard let doneMarker = Self.findDelimitedKeyword(
            "done",
            in: loopClause,
            from: bodyStart
        ) else {
            return .failure(.parserError("\(keyword): expected 'done'"))
        }

        let body = String(loopClause[bodyStart..<doneMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return .failure(.parserError("\(keyword): expected non-empty loop body"))
        }

        let tail = String(loopClause[doneMarker.afterKeywordIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingAction: TrailingAction
        switch Self.parseTrailingAction(from: tail, context: keyword) {
        case let .success(action):
            trailingAction = action
        case let .failure(error):
            return .failure(error)
        }

        return .success(
            SimpleWhileLoop(
                leadingCommands: leadingCommands,
                condition: condition,
                isUntil: isUntil,
                body: body,
                trailingAction: trailingAction
            )
        )
    }

    func executeSimpleCaseBlockIfPresent(
        commandLine: String,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        let parsedCase = parseSimpleCaseBlock(commandLine)
        switch parsedCase {
        case .notCaseBlock:
            return nil
        case let .failure(error):
            var stderr = prefixedStderr
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
        case let .success(caseBlock):
            var combinedOut = Data()
            var combinedErr = Data()
            var lastExitCode: Int32 = 0

            if let leadingCommands = caseBlock.leadingCommands,
               !leadingCommands.isEmpty {
                let leadingResult = await executeStandardCommandLine(
                    leadingCommands,
                    stdin: stdin
                )
                combinedOut.append(leadingResult.stdout)
                combinedErr.append(leadingResult.stderr)
                lastExitCode = leadingResult.exitCode
            }

            let subject = Self.evaluateCaseWord(
                caseBlock.subject,
                environment: environmentStore
            )
            var selectedBody: String?
            for arm in caseBlock.arms {
                if arm.patterns.contains(where: { Self.casePatternMatches($0, value: subject, environment: environmentStore) }) {
                    selectedBody = arm.body
                    break
                }
            }

            if let selectedBody, !selectedBody.isEmpty {
                let bodyResult = await executeStandardCommandLine(
                    selectedBody,
                    stdin: stdin
                )
                combinedOut.append(bodyResult.stdout)
                combinedErr.append(bodyResult.stderr)
                lastExitCode = bodyResult.exitCode
            } else {
                lastExitCode = 0
            }

            var result = CommandResult(
                stdout: combinedOut,
                stderr: combinedErr,
                exitCode: lastExitCode
            )
            await applyTrailingAction(caseBlock.trailingAction, to: &result)
            mergePrefixedStderr(prefixedStderr, into: &result)
            return result
        }
    }

    func parseSimpleCaseBlock(_ commandLine: String) -> SimpleCaseBlockParseResult {
        var start = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &start)

        if commandLine[start...].hasPrefix("case") {
            return parseCaseClause(
                String(commandLine[start...]),
                leadingCommands: nil
            )
        }

        guard let marker = Self.findDelimitedKeyword(
            "case",
            in: commandLine,
            from: start
        ) else {
            return .notCaseBlock
        }

        let prefix = String(commandLine[start..<marker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            return .notCaseBlock
        }

        return parseCaseClause(
            String(commandLine[marker.keywordIndex...]),
            leadingCommands: prefix
        )
    }

    func parseCaseClause(
        _ clause: String,
        leadingCommands: String?
    ) -> SimpleCaseBlockParseResult {
        var index = clause.startIndex
        Self.skipWhitespace(in: clause, index: &index)

        guard Self.consumeKeyword("case", in: clause, index: &index) else {
            return .notCaseBlock
        }

        Self.skipWhitespace(in: clause, index: &index)
        guard let inRange = Self.findKeywordTokenRange(
            "in",
            in: clause,
            from: index
        ) else {
            return .failure(.parserError("case: expected 'in'"))
        }

        let subject = String(clause[index..<inRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty {
            return .failure(.parserError("case: expected subject"))
        }

        var bodyStart = inRange.upperBound
        Self.skipWhitespace(in: clause, index: &bodyStart)
        guard let esacMarker = Self.findDelimitedKeyword(
            "esac",
            in: clause,
            from: bodyStart
        ) else {
            return .failure(.parserError("case: expected 'esac'"))
        }

        let armsRaw = String(clause[bodyStart..<esacMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let arms: [SimpleCaseArm]
        do {
            arms = try Self.parseCaseArms(armsRaw)
        } catch let shellError as ShellError {
            return .failure(shellError)
        } catch {
            return .failure(.parserError("case: \(error)"))
        }

        let tail = String(clause[esacMarker.afterKeywordIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingAction: TrailingAction
        switch Self.parseTrailingAction(from: tail, context: "case") {
        case let .success(action):
            trailingAction = action
        case let .failure(error):
            return .failure(error)
        }

        return .success(
            SimpleCaseBlock(
                leadingCommands: leadingCommands,
                subject: subject,
                arms: arms,
                trailingAction: trailingAction
            )
        )
    }

    func executeConditionalExpression(
        _ condition: String,
        stdin: Data
    ) async -> CommandResult {
        if let testResult = await evaluateTestConditionIfPresent(condition) {
            return testResult
        }
        return await executeStandardCommandLine(condition, stdin: stdin)
    }

    func evaluateTestConditionIfPresent(_ condition: String) async -> CommandResult? {
        let tokens: [LexToken]
        do {
            tokens = try ShellLexer.tokenize(condition)
        } catch {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(error)\n".utf8),
                exitCode: 2
            )
        }

        var words: [String] = []
        for token in tokens {
            guard case let .word(word) = token else {
                return nil
            }
            words.append(Self.expandWord(word, environment: environmentStore))
        }

        guard let first = words.first else {
            return nil
        }

        var expression = words
        if first == "test" {
            expression.removeFirst()
        } else if first == "[" {
            guard expression.last == "]" else {
                return CommandResult(
                    stdout: Data(),
                    stderr: Data("test: missing ']'\n".utf8),
                    exitCode: 2
                )
            }
            expression.removeFirst()
            expression.removeLast()
        } else {
            return nil
        }

        return await evaluateTestExpression(expression)
    }

    func evaluateTestExpression(_ expression: [String]) async -> CommandResult {
        if expression.isEmpty {
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
        }

        if expression.count == 1 {
            let isTrue = !expression[0].isEmpty
            return CommandResult(
                stdout: Data(),
                stderr: Data(),
                exitCode: isTrue ? 0 : 1
            )
        }

        if expression.count == 2 {
            let op = expression[0]
            let value = expression[1]

            switch op {
            case "-n":
                return CommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: value.isEmpty ? 1 : 0
                )
            case "-z":
                return CommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: value.isEmpty ? 0 : 1
                )
            case "-e", "-f", "-d":
                let path = WorkspacePath(
                    normalizing: value,
                    relativeTo: WorkspacePath(normalizing: currentDirectoryStore)
                )
                guard await filesystemStore.exists(path: path) else {
                    return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
                }

                guard let info = try? await filesystemStore.stat(path: path) else {
                    return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
                }

                let passed: Bool
                switch op {
                case "-e":
                    passed = true
                case "-f":
                    passed = !info.isDirectory
                case "-d":
                    passed = info.isDirectory
                default:
                    passed = false
                }
                return CommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: passed ? 0 : 1
                )
            default:
                return CommandResult(
                    stdout: Data(),
                    stderr: Data("test: unsupported expression\n".utf8),
                    exitCode: 2
                )
            }
        }

        if expression.count == 3 {
            let lhs = expression[0]
            let op = expression[1]
            let rhs = expression[2]

            switch op {
            case "=", "==":
                return CommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: lhs == rhs ? 0 : 1
                )
            case "!=":
                return CommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: lhs != rhs ? 0 : 1
                )
            case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
                guard let leftValue = Int(lhs), let rightValue = Int(rhs) else {
                    return CommandResult(
                        stdout: Data(),
                        stderr: Data("test: integer expression expected\n".utf8),
                        exitCode: 2
                    )
                }
                let passed: Bool
                switch op {
                case "-eq":
                    passed = leftValue == rightValue
                case "-ne":
                    passed = leftValue != rightValue
                case "-lt":
                    passed = leftValue < rightValue
                case "-le":
                    passed = leftValue <= rightValue
                case "-gt":
                    passed = leftValue > rightValue
                case "-ge":
                    passed = leftValue >= rightValue
                default:
                    passed = false
                }
                return CommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: passed ? 0 : 1
                )
            default:
                return CommandResult(
                    stdout: Data(),
                    stderr: Data("test: unsupported expression\n".utf8),
                    exitCode: 2
                )
            }
        }

        return CommandResult(
            stdout: Data(),
            stderr: Data("test: unsupported expression\n".utf8),
            exitCode: 2
        )
    }

    func applyTrailingAction(
        _ action: TrailingAction,
        to result: inout CommandResult
    ) async {
        switch action {
        case .none:
            return
        case let .redirections(redirections):
            await applyRedirections(redirections, to: &result)
        case let .pipeline(pipeline):
            do {
                let parsed = try ShellParser.parse(pipeline)
                let pipelineExecution = await executeParsedLine(
                    parsedLine: parsed,
                    stdin: result.stdout,
                    currentDirectory: currentDirectoryStore,
                    environment: environmentStore,
                    shellFunctions: shellFunctionStore,
                    jobControl: jobManager
                )
                currentDirectoryStore = pipelineExecution.currentDirectory
                environmentStore = pipelineExecution.environment
                environmentStore["PWD"] = currentDirectoryStore

                var mergedStderr = result.stderr
                mergedStderr.append(pipelineExecution.result.stderr)
                result = CommandResult(
                    stdout: pipelineExecution.result.stdout,
                    stderr: mergedStderr,
                    exitCode: pipelineExecution.result.exitCode
                )
            } catch {
                result.stdout.removeAll(keepingCapacity: true)
                result.stderr.append(Data("\(error)\n".utf8))
                result.exitCode = 2
            }
        }
    }

    func mergePrefixedStderr(_ prefixedStderr: Data, into result: inout CommandResult) {
        guard !prefixedStderr.isEmpty else {
            return
        }

        var merged = prefixedStderr
        merged.append(result.stderr)
        result.stderr = merged
    }

    func applyRedirections(
        _ redirections: [Redirection],
        to result: inout CommandResult
    ) async {
        for redirection in redirections {
            switch redirection.type {
            case .stdin:
                continue
            case .stderrToStdout:
                result.stdout.append(result.stderr)
                result.stderr.removeAll(keepingCapacity: true)
            case .stdoutTruncate, .stdoutAppend:
                guard let targetWord = redirection.target else { continue }
                let target = Self.expandWord(
                    targetWord,
                    environment: environmentStore
                )
                let path = WorkspacePath(
                    normalizing: target,
                    relativeTo: WorkspacePath(normalizing: currentDirectoryStore)
                )
                do {
                    try await filesystemStore.writeFile(
                        path: path,
                        data: result.stdout,
                        append: redirection.type == .stdoutAppend
                    )
                    result.stdout.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            case .stderrTruncate, .stderrAppend:
                guard let targetWord = redirection.target else { continue }
                let target = Self.expandWord(
                    targetWord,
                    environment: environmentStore
                )
                let path = WorkspacePath(
                    normalizing: target,
                    relativeTo: WorkspacePath(normalizing: currentDirectoryStore)
                )
                do {
                    try await filesystemStore.writeFile(
                        path: path,
                        data: result.stderr,
                        append: redirection.type == .stderrAppend
                    )
                    result.stderr.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            case .stdoutAndErrTruncate, .stdoutAndErrAppend:
                guard let targetWord = redirection.target else { continue }
                let target = Self.expandWord(
                    targetWord,
                    environment: environmentStore
                )
                let path = WorkspacePath(
                    normalizing: target,
                    relativeTo: WorkspacePath(normalizing: currentDirectoryStore)
                )
                var combined = Data()
                combined.append(result.stdout)
                combined.append(result.stderr)
                do {
                    try await filesystemStore.writeFile(
                        path: path,
                        data: combined,
                        append: redirection.type == .stdoutAndErrAppend
                    )
                    result.stdout.removeAll(keepingCapacity: true)
                    result.stderr.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            }
        }
    }

    static func parseLoopValues(
        _ rawValues: String,
        environment: [String: String]
    ) throws -> [String] {
        let tokens = try ShellLexer.tokenize(rawValues)
        var values: [String] = []
        for token in tokens {
            guard case let .word(word) = token else {
                throw ShellError.parserError("for: unsupported loop value syntax")
            }
            values.append(expandWord(word, environment: environment))
        }
        return values
    }

    static func parseCStyleForHeader(
        _ commandLine: String,
        index: inout String.Index
    ) -> (initializer: String, condition: String, increment: String)? {
        guard Self.consumeLiteral("(", in: commandLine, index: &index),
              Self.consumeLiteral("(", in: commandLine, index: &index) else {
            return nil
        }

        let secondOpen = commandLine.index(before: index)
        guard let capture = captureBalancedDoubleParentheses(
            in: commandLine,
            secondOpen: secondOpen
        ) else {
            return nil
        }

        let components = splitCStyleForComponents(capture.content)
        guard components.count == 3 else {
            return nil
        }

        index = capture.endIndex
        return (
            initializer: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
            condition: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
            increment: components[2].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func captureBalancedDoubleParentheses(
        in string: String,
        secondOpen: String.Index
    ) -> (content: String, endIndex: String.Index)? {
        var depth = 1
        var cursor = string.index(after: secondOpen)
        let contentStart = cursor

        while cursor < string.endIndex {
            if string[cursor] == "(" {
                let next = string.index(after: cursor)
                if next < string.endIndex, string[next] == "(" {
                    depth += 1
                    cursor = string.index(after: next)
                    continue
                }
            } else if string[cursor] == ")" {
                let next = string.index(after: cursor)
                if next < string.endIndex, string[next] == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (
                            content: String(string[contentStart..<cursor]),
                            endIndex: string.index(after: next)
                        )
                    }
                    cursor = string.index(after: next)
                    continue
                }
            }
            cursor = string.index(after: cursor)
        }

        return nil
    }

    static func splitCStyleForComponents(_ value: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0
        var quote: QuoteKind = .none
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]

            if character == "\\", quote != .single {
                current.append(character)
                let next = value.index(after: index)
                if next < value.endIndex {
                    current.append(value[next])
                    index = value.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                current.append(character)
                index = value.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                current.append(character)
                index = value.index(after: index)
                continue
            }

            if quote == .none {
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if character == ";", depth == 0 {
                    components.append(current)
                    current = ""
                    index = value.index(after: index)
                    continue
                }
            }

            current.append(character)
            index = value.index(after: index)
        }

        components.append(current)
        return components
    }

    func executeCStyleArithmeticStatement(_ statement: String) -> ShellError? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasSuffix("++") || trimmed.hasSuffix("--") {
            let suffixLength = 2
            let end = trimmed.index(trimmed.endIndex, offsetBy: -suffixLength)
            let name = String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidIdentifierName(name) else {
                return .parserError("for: invalid increment target '\(name)'")
            }
            let current = Int(environmentStore[name] ?? "") ?? 0
            environmentStore[name] = String(trimmed.hasSuffix("++") ? current + 1 : current - 1)
            return nil
        }

        for op in ["+=", "-=", "*=", "/=", "%="] {
            if let range = trimmed.range(of: op) {
                let name = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidIdentifierName(name) else {
                    return .parserError("for: invalid assignment target '\(name)'")
                }
                let rhsExpression = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let rhs = ArithmeticEvaluator.evaluate(
                    rhsExpression,
                    environment: environmentStore
                ) else {
                    return .parserError("for: invalid arithmetic expression '\(rhsExpression)'")
                }

                let lhs = Int(environmentStore[name] ?? "") ?? 0
                switch op {
                case "+=":
                    environmentStore[name] = String(lhs + rhs)
                case "-=":
                    environmentStore[name] = String(lhs - rhs)
                case "*=":
                    environmentStore[name] = String(lhs * rhs)
                case "/=":
                    if rhs == 0 {
                        return .parserError("for: division by zero")
                    }
                    environmentStore[name] = String(lhs / rhs)
                case "%=":
                    if rhs == 0 {
                        return .parserError("for: division by zero")
                    }
                    environmentStore[name] = String(lhs % rhs)
                default:
                    break
                }
                return nil
            }
        }

        if let equals = trimmed.firstIndex(of: "="), equals != trimmed.startIndex {
            let name = String(trimmed[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidIdentifierName(name) else {
                return .parserError("for: invalid assignment target '\(name)'")
            }
            let rhsExpression = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = ArithmeticEvaluator.evaluate(
                rhsExpression,
                environment: environmentStore
            ) else {
                return .parserError("for: invalid arithmetic expression '\(rhsExpression)'")
            }
            environmentStore[name] = String(value)
            return nil
        }

        guard ArithmeticEvaluator.evaluate(trimmed, environment: environmentStore) != nil else {
            return .parserError("for: unsupported arithmetic statement '\(trimmed)'")
        }

        return nil
    }

    static func parseCaseArms(_ rawArms: String) throws -> [SimpleCaseArm] {
        let trimmed = rawArms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var arms: [SimpleCaseArm] = []
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            while index < trimmed.endIndex &&
                (trimmed[index].isWhitespace || trimmed[index] == ";") {
                index = trimmed.index(after: index)
            }
            guard index < trimmed.endIndex else {
                break
            }

            guard let closeParen = findUnquotedCharacter(
                ")",
                in: trimmed,
                from: index
            ) else {
                throw ShellError.parserError("case: expected ')' in pattern arm")
            }

            let patternChunk = String(trimmed[index..<closeParen])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if patternChunk.isEmpty {
                throw ShellError.parserError("case: expected pattern before ')'")
            }

            let bodyStart = trimmed.index(after: closeParen)
            let bodyEnd: String.Index
            if let terminator = findUnquotedDoubleSemicolon(
                in: trimmed,
                from: bodyStart
            ) {
                bodyEnd = terminator.lowerBound
                index = terminator.upperBound
            } else {
                bodyEnd = trimmed.endIndex
                index = trimmed.endIndex
            }

            let body = String(trimmed[bodyStart..<bodyEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let patterns = splitCasePatterns(patternChunk)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if patterns.isEmpty {
                throw ShellError.parserError("case: expected at least one pattern")
            }

            arms.append(SimpleCaseArm(patterns: patterns, body: body))
        }

        return arms
    }

    static func evaluateCaseWord(
        _ raw: String,
        environment: [String: String]
    ) -> String {
        do {
            let tokens = try ShellLexer.tokenize(raw)
            let words = tokens.compactMap { token -> String? in
                guard case let .word(word) = token else {
                    return nil
                }
                return expandWord(word, environment: environment)
            }
            if words.isEmpty {
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return words.joined(separator: " ")
        } catch {
            return expandVariables(
                in: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                environment: environment
            )
        }
    }

    static func casePatternMatches(
        _ rawPattern: String,
        value: String,
        environment: [String: String]
    ) -> Bool {
        let expanded = evaluateCaseWord(rawPattern, environment: environment)
        guard let regex = try? NSRegularExpression(pattern: WorkspacePath.globToRegex(expanded)) else {
            return expanded == value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    static func splitCasePatterns(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: QuoteKind = .none
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]

            if character == "\\", quote != .single {
                current.append(character)
                let next = value.index(after: index)
                if next < value.endIndex {
                    current.append(value[next])
                    index = value.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                current.append(character)
                index = value.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                current.append(character)
                index = value.index(after: index)
                continue
            }

            if quote == .none, character == "|" {
                parts.append(current)
                current = ""
                index = value.index(after: index)
                continue
            }

            current.append(character)
            index = value.index(after: index)
        }

        parts.append(current)
        return parts
    }

    static func findUnquotedCharacter(
        _ target: Character,
        in value: String,
        from start: String.Index
    ) -> String.Index? {
        var quote: QuoteKind = .none
        var index = start

        while index < value.endIndex {
            let character = value[index]

            if character == "\\", quote != .single {
                let next = value.index(after: index)
                if next < value.endIndex {
                    index = value.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = value.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = value.index(after: index)
                continue
            }

            if quote == .none, character == target {
                return index
            }

            index = value.index(after: index)
        }

        return nil
    }

    static func findUnquotedDoubleSemicolon(
        in value: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var quote: QuoteKind = .none
        var index = start

        while index < value.endIndex {
            let character = value[index]

            if character == "\\", quote != .single {
                let next = value.index(after: index)
                if next < value.endIndex {
                    index = value.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = value.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = value.index(after: index)
                continue
            }

            if quote == .none, character == ";" {
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == ";" {
                    return index..<value.index(after: next)
                }
            }

            index = value.index(after: index)
        }

        return nil
    }
}
