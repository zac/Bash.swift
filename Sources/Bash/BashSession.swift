import Foundation

public final actor BashSession {
    private let filesystemStore: any ShellFilesystem
    private let options: SessionOptions
    private let jobManager: ShellJobManager

    private var currentDirectoryStore: String
    private var environmentStore: [String: String]
    private var historyStore: [String]
    private var commandRegistry: [String: AnyBuiltinCommand]
    private var shellFunctionStore: [String: String]

    public var currentDirectory: String {
        currentDirectoryStore
    }

    public var environment: [String: String] {
        environmentStore
    }

    public init(rootDirectory: URL, options: SessionOptions = .init()) async throws {
        let filesystem = options.filesystem
        try filesystem.configure(rootDirectory: rootDirectory)
        try await self.init(options: options, configuredFilesystem: filesystem)
    }

    public init(options: SessionOptions = .init()) async throws {
        let filesystem = options.filesystem
        guard let configurable = filesystem as? any SessionConfigurableFilesystem else {
            throw ShellError.unsupported("filesystem requires rootDirectory initializer")
        }

        try configurable.configureForSession()
        try await self.init(options: options, configuredFilesystem: filesystem)
    }

    public func run(_ commandLine: String, stdin: Data = Data()) async -> CommandResult {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }

        historyStore.append(trimmed)
        if historyStore.count > options.maxHistory {
            historyStore.removeFirst(historyStore.count - options.maxHistory)
        }

        var substitution = await expandCommandSubstitutions(in: commandLine)
        if let error = substitution.error {
            var stderr = substitution.stderr
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
        }
        var executableLine = substitution.commandLine
        let functionOutcome = parseAndRegisterFunctionDefinitions(in: executableLine)
        if let error = functionOutcome.error {
            substitution.stderr.append(Data("\(error)\n".utf8))
            return CommandResult(
                stdout: Data(),
                stderr: substitution.stderr,
                exitCode: 2
            )
        }

        executableLine = functionOutcome.remaining
        if executableLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CommandResult(
                stdout: Data(),
                stderr: substitution.stderr,
                exitCode: 0
            )
        }

        if let forResult = await executeSimpleForLoopIfPresent(
            commandLine: executableLine,
            stdin: stdin,
            prefixedStderr: substitution.stderr
        ) {
            return forResult
        }

        if let ifResult = await executeSimpleIfBlockIfPresent(
            commandLine: executableLine,
            stdin: stdin,
            prefixedStderr: substitution.stderr
        ) {
            return ifResult
        }

        if let whileResult = await executeSimpleWhileLoopIfPresent(
            commandLine: executableLine,
            stdin: stdin,
            prefixedStderr: substitution.stderr
        ) {
            return whileResult
        }

        var result = await executeStandardCommandLine(
            executableLine,
            stdin: stdin
        )

        if !substitution.stderr.isEmpty {
            var merged = substitution.stderr
            merged.append(result.stderr)
            result.stderr = merged
        }

        return result
    }

    public func register(_ command: any BuiltinCommand.Type) async {
        let erased = command._toAnyBuiltinCommand()
        await register(erased)
    }

    func register(_ command: AnyBuiltinCommand) async {
        commandRegistry[command.name] = command

        for alias in command.aliases {
            commandRegistry[alias] = command
        }

        if options.layout == .unixLike {
            await createCommandStub(named: command.name)
            for alias in command.aliases {
                await createCommandStub(named: alias)
            }
        }
    }

    private func setupLayout() async throws {
        switch options.layout {
        case .rootOnly:
            // Backends are configured with a root by construction. Creating "/"
            // can resolve to the parent of the jailed root for some adapters.
            break
        case .unixLike:
            for path in ["/home/user", "/bin", "/usr/bin", "/tmp"] {
                try await filesystemStore.createDirectory(path: path, recursive: true)
            }
        }
    }

    private func createCommandStub(named commandName: String) async {
        let content = "#!/bin/sh\n# Bash built-in: \(commandName)\n"
        let data = Data(content.utf8)

        for directory in ["/bin", "/usr/bin"] {
            let path = "\(directory)/\(commandName)"
            if await filesystemStore.exists(path: path) {
                continue
            }

            do {
                try await filesystemStore.writeFile(path: path, data: data, append: false)
                try await filesystemStore.setPermissions(path: path, permissions: 0o755)
            } catch {
                // Best effort for command lookup stubs.
            }
        }
    }

    private init(options: SessionOptions, configuredFilesystem: any ShellFilesystem) async throws {
        self.options = options
        filesystemStore = configuredFilesystem
        jobManager = ShellJobManager()

        commandRegistry = [:]
        shellFunctionStore = [:]
        historyStore = []
        currentDirectoryStore = Self.initialCurrentDirectory(for: options.layout)
        environmentStore = Self.defaultEnvironment(
            for: options.layout,
            currentDirectory: currentDirectoryStore,
            initialEnvironment: options.initialEnvironment
        )

        try await setupLayout()
        await registerDefaultCommands()
    }

    private static func initialCurrentDirectory(for layout: SessionLayout) -> String {
        switch layout {
        case .unixLike:
            return "/home/user"
        case .rootOnly:
            return "/"
        }
    }

    private static func defaultEnvironment(
        for layout: SessionLayout,
        currentDirectory: String,
        initialEnvironment: [String: String]
    ) -> [String: String] {
        let home: String
        switch layout {
        case .unixLike:
            home = "/home/user"
        case .rootOnly:
            home = "/"
        }

        var defaults: [String: String] = [
            "HOME": home,
            "PWD": currentDirectory,
            "PATH": "/bin:/usr/bin",
            "USER": "user",
            "TMPDIR": "/tmp",
        ]

        defaults.merge(initialEnvironment) { _, rhs in rhs }
        return defaults
    }

    private struct CommandSubstitutionOutcome {
        var commandLine: String
        var stderr: Data
        var error: ShellError?
    }

    private struct FunctionDefinitionParseOutcome {
        var remaining: String
        var error: ShellError?
    }

    private struct SimpleForLoop {
        var variableName: String
        var values: [String]
        var body: String
        var trailingAction: TrailingAction
    }

    private enum SimpleForLoopParseResult {
        case notForLoop
        case success(SimpleForLoop)
        case failure(ShellError)
    }

    private struct SimpleIfBlock {
        var condition: String
        var thenBody: String
        var elseBody: String?
        var trailingAction: TrailingAction
    }

    private enum SimpleIfBlockParseResult {
        case notIfBlock
        case success(SimpleIfBlock)
        case failure(ShellError)
    }

    private struct SimpleWhileLoop {
        var leadingCommands: String?
        var condition: String
        var body: String
        var trailingAction: TrailingAction
    }

    private enum SimpleWhileLoopParseResult {
        case notWhileLoop
        case success(SimpleWhileLoop)
        case failure(ShellError)
    }

    private enum TrailingAction {
        case none
        case redirections([Redirection])
        case pipeline(String)
    }

    private struct DelimitedKeywordMatch {
        var separatorIndex: String.Index
        var keywordIndex: String.Index
        var afterKeywordIndex: String.Index
    }

    private func executeParsedLine(
        parsedLine: ParsedLine,
        stdin: Data,
        currentDirectory: String,
        environment: [String: String],
        shellFunctions: [String: String],
        jobControl: (any ShellJobControlling)?
    ) async -> ShellExecutionResult {
        let secretPolicy = options.secretPolicy
        let secretResolver = options.secretResolver
        let secretOutputRedactor = options.secretOutputRedactor
        let secretTracker = secretPolicy == .off ? nil : SecretExposureTracker()

        var execution = await ShellExecutor.execute(
            parsedLine: parsedLine,
            stdin: stdin,
            filesystem: filesystemStore,
            currentDirectory: currentDirectory,
            environment: environment,
            history: historyStore,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: options.enableGlobbing,
            jobControl: jobControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )

        if let secretTracker {
            let replacements = await secretTracker.snapshot()
            if !replacements.isEmpty {
                execution.result.stdout = secretOutputRedactor.redact(
                    data: execution.result.stdout,
                    replacements: replacements
                )
                execution.result.stderr = secretOutputRedactor.redact(
                    data: execution.result.stderr,
                    replacements: replacements
                )
            }
        }

        return execution
    }

    private func executeStandardCommandLine(
        _ commandLine: String,
        stdin: Data
    ) async -> CommandResult {
        do {
            let parsed = try ShellParser.parse(commandLine)
            let execution = await executeParsedLine(
                parsedLine: parsed,
                stdin: stdin,
                currentDirectory: currentDirectoryStore,
                environment: environmentStore,
                shellFunctions: shellFunctionStore,
                jobControl: jobManager
            )
            currentDirectoryStore = execution.currentDirectory
            environmentStore = execution.environment
            environmentStore["PWD"] = currentDirectoryStore
            return execution.result
        } catch {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(error)\n".utf8),
                exitCode: 2
            )
        }
    }

    private func expandCommandSubstitutions(in commandLine: String) async -> CommandSubstitutionOutcome {
        var output = ""
        var stderr = Data()
        var quote: QuoteKind = .none
        var index = commandLine.startIndex

        while index < commandLine.endIndex {
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

            if quote != .single, character == "$" {
                let next = commandLine.index(after: index)
                if next < commandLine.endIndex, commandLine[next] == "(" {
                    let secondOpen = commandLine.index(after: next)
                    if secondOpen < commandLine.endIndex, commandLine[secondOpen] == "(" {
                        output.append(character)
                        index = commandLine.index(after: index)
                        continue
                    }
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
            error: nil
        )
    }

    private func evaluateCommandSubstitution(_ command: String) async -> CommandSubstitutionOutcome {
        let nested = await expandCommandSubstitutions(in: command)
        if let error = nested.error {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: error
            )
        }

        let parsed: ParsedLine
        do {
            parsed = try ShellParser.parse(nested.commandLine)
        } catch let shellError as ShellError {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: shellError
            )
        } catch {
            return CommandSubstitutionOutcome(
                commandLine: "",
                stderr: nested.stderr,
                error: .parserError("\(error)")
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
            error: nil
        )
    }

    private func parseAndRegisterFunctionDefinitions(
        in commandLine: String
    ) -> FunctionDefinitionParseOutcome {
        var functionStore = shellFunctionStore
        let parsed = Self.parseFunctionDefinitions(
            in: commandLine,
            functionStore: &functionStore
        )
        if parsed.error == nil {
            shellFunctionStore = functionStore
        }
        return parsed
    }

    private func executeSimpleForLoopIfPresent(
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

            for value in loop.values {
                environmentStore[loop.variableName] = value
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

    private func parseSimpleForLoop(_ commandLine: String) -> SimpleForLoopParseResult {
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

        let bodyStart = valuesMarker.afterKeywordIndex
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
                variableName: variableName,
                values: values,
                body: body,
                trailingAction: trailingAction
            )
        )
    }

    private func executeSimpleIfBlockIfPresent(
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
            let conditionResult = await executeConditionalExpression(
                ifBlock.condition,
                stdin: stdin
            )

            var combinedOut = conditionResult.stdout
            var combinedErr = conditionResult.stderr
            var lastExitCode: Int32 = conditionResult.exitCode

            let selectedBody: String?
            if conditionResult.exitCode == 0 {
                selectedBody = ifBlock.thenBody
            } else {
                selectedBody = ifBlock.elseBody
            }

            if let selectedBody, !selectedBody.isEmpty {
                let bodyResult = await executeStandardCommandLine(
                    selectedBody,
                    stdin: stdin
                )
                combinedOut.append(bodyResult.stdout)
                combinedErr.append(bodyResult.stderr)
                lastExitCode = bodyResult.exitCode
            } else if conditionResult.exitCode != 0 {
                lastExitCode = 0
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

    private func parseSimpleIfBlock(_ commandLine: String) -> SimpleIfBlockParseResult {
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

        let bodyStart = thenMarker.afterKeywordIndex
        guard let fiMarker = Self.findDelimitedKeyword(
            "fi",
            in: commandLine,
            from: bodyStart
        ) else {
            return .failure(.parserError("if: expected 'fi'"))
        }

        let elseMarker = Self.findDelimitedKeyword(
            "else",
            in: commandLine,
            from: bodyStart,
            end: fiMarker.separatorIndex
        )

        let thenBody: String
        let elseBody: String?
        if let elseMarker {
            thenBody = String(commandLine[bodyStart..<elseMarker.separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            elseBody = String(commandLine[elseMarker.afterKeywordIndex..<fiMarker.separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            thenBody = String(commandLine[bodyStart..<fiMarker.separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            elseBody = nil
        }

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
                condition: condition,
                thenBody: thenBody,
                elseBody: elseBody,
                trailingAction: trailingAction
            )
        )
    }

    private func executeSimpleWhileLoopIfPresent(
        commandLine: String,
        stdin: Data,
        prefixedStderr: Data
    ) async -> CommandResult? {
        let parsedWhile = parseSimpleWhileLoop(commandLine)
        switch parsedWhile {
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
                if iterations > 10_000 {
                    combinedErr.append(Data("while: exceeded max iterations\n".utf8))
                    lastExitCode = 2
                    break
                }

                let conditionResult = await executeConditionalExpression(
                    loop.condition,
                    stdin: stdin
                )
                combinedOut.append(conditionResult.stdout)
                combinedErr.append(conditionResult.stderr)

                if conditionResult.exitCode != 0 {
                    if conditionResult.exitCode > 1, !didRunBody {
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

    private func parseSimpleWhileLoop(_ commandLine: String) -> SimpleWhileLoopParseResult {
        var start = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &start)

        if commandLine[start...].hasPrefix("while") {
            return parseWhileClause(
                String(commandLine[start...]),
                leadingCommands: nil
            )
        }

        guard let whileMarker = Self.findDelimitedKeyword(
            "while",
            in: commandLine,
            from: start
        ) else {
            return .notWhileLoop
        }

        let prefix = String(commandLine[start..<whileMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            return .notWhileLoop
        }

        return parseWhileClause(
            String(commandLine[whileMarker.keywordIndex...]),
            leadingCommands: prefix
        )
    }

    private func parseWhileClause(
        _ whileClause: String,
        leadingCommands: String?
    ) -> SimpleWhileLoopParseResult {
        var index = whileClause.startIndex
        Self.skipWhitespace(in: whileClause, index: &index)
        guard Self.consumeKeyword("while", in: whileClause, index: &index) else {
            return .notWhileLoop
        }

        Self.skipWhitespace(in: whileClause, index: &index)
        guard let doMarker = Self.findDelimitedKeyword(
            "do",
            in: whileClause,
            from: index
        ) else {
            return .failure(.parserError("while: expected 'do'"))
        }

        let condition = String(whileClause[index..<doMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if condition.isEmpty {
            return .failure(.parserError("while: expected condition command"))
        }

        let bodyStart = doMarker.afterKeywordIndex
        guard let doneMarker = Self.findDelimitedKeyword(
            "done",
            in: whileClause,
            from: bodyStart
        ) else {
            return .failure(.parserError("while: expected 'done'"))
        }

        let body = String(whileClause[bodyStart..<doneMarker.separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return .failure(.parserError("while: expected non-empty loop body"))
        }

        let tail = String(whileClause[doneMarker.afterKeywordIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingAction: TrailingAction
        switch Self.parseTrailingAction(from: tail, context: "while") {
        case let .success(action):
            trailingAction = action
        case let .failure(error):
            return .failure(error)
        }

        return .success(
            SimpleWhileLoop(
                leadingCommands: leadingCommands,
                condition: condition,
                body: body,
                trailingAction: trailingAction
            )
        )
    }

    private func executeConditionalExpression(
        _ condition: String,
        stdin: Data
    ) async -> CommandResult {
        if let testResult = await evaluateTestConditionIfPresent(condition) {
            return testResult
        }
        return await executeStandardCommandLine(condition, stdin: stdin)
    }

    private func evaluateTestConditionIfPresent(_ condition: String) async -> CommandResult? {
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

    private func evaluateTestExpression(_ expression: [String]) async -> CommandResult {
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
                let path = PathUtils.normalize(
                    path: value,
                    currentDirectory: currentDirectoryStore
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

    private func applyTrailingAction(
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

    private func mergePrefixedStderr(_ prefixedStderr: Data, into result: inout CommandResult) {
        guard !prefixedStderr.isEmpty else {
            return
        }

        var merged = prefixedStderr
        merged.append(result.stderr)
        result.stderr = merged
    }

    private func applyRedirections(
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
                let path = PathUtils.normalize(
                    path: target,
                    currentDirectory: currentDirectoryStore
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
                let path = PathUtils.normalize(
                    path: target,
                    currentDirectory: currentDirectoryStore
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
                let path = PathUtils.normalize(
                    path: target,
                    currentDirectory: currentDirectoryStore
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

    private static func captureCommandSubstitution(
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

    private static func parseFunctionDefinitions(
        in commandLine: String,
        functionStore: inout [String: String]
    ) -> FunctionDefinitionParseOutcome {
        var index = commandLine.startIndex
        Self.skipWhitespace(in: commandLine, index: &index)
        var parsedAny = false

        while index < commandLine.endIndex {
            let definitionStart = index

            guard let functionName = Self.readIdentifier(in: commandLine, index: &index) else {
                let remaining = String(commandLine[definitionStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return FunctionDefinitionParseOutcome(
                    remaining: parsedAny ? remaining : commandLine,
                    error: nil
                )
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            guard Self.consumeLiteral("(", in: commandLine, index: &index) else {
                let remaining = String(commandLine[definitionStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return FunctionDefinitionParseOutcome(
                    remaining: parsedAny ? remaining : commandLine,
                    error: nil
                )
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            guard Self.consumeLiteral(")", in: commandLine, index: &index) else {
                return FunctionDefinitionParseOutcome(
                    remaining: commandLine,
                    error: .parserError("function \(functionName): expected ')'"))
            }

            Self.skipWhitespace(in: commandLine, index: &index)
            guard index < commandLine.endIndex, commandLine[index] == "{" else {
                return FunctionDefinitionParseOutcome(
                    remaining: commandLine,
                    error: .parserError("function \(functionName): expected '{'"))
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

    private static func captureBalancedBraces(
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

    private static func findDelimitedKeyword(
        _ keyword: String,
        in commandLine: String,
        from startIndex: String.Index,
        end: String.Index? = nil
    ) -> DelimitedKeywordMatch? {
        var quote: QuoteKind = .none
        var index = startIndex
        let endIndex = end ?? commandLine.endIndex

        while index < endIndex {
            let character = commandLine[index]

            if character == "\\", quote != .single {
                let next = commandLine.index(after: index)
                if next < endIndex {
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

            if quote == .none, character == ";" || character == "\n" {
                var cursor = commandLine.index(after: index)
                while cursor < endIndex, commandLine[cursor].isWhitespace {
                    cursor = commandLine.index(after: cursor)
                }
                guard cursor < endIndex else {
                    return nil
                }

                guard commandLine[cursor...].hasPrefix(keyword) else {
                    index = commandLine.index(after: index)
                    continue
                }

                let afterKeyword = commandLine.index(
                    cursor,
                    offsetBy: keyword.count
                )
                if afterKeyword < commandLine.endIndex,
                   Self.isIdentifierCharacter(commandLine[afterKeyword]) {
                    index = commandLine.index(after: index)
                    continue
                }

                return DelimitedKeywordMatch(
                    separatorIndex: index,
                    keywordIndex: cursor,
                    afterKeywordIndex: afterKeyword
                )
            }

            index = commandLine.index(after: index)
        }

        return nil
    }

    private static func parseLoopValues(
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

    private static func parseTrailingAction(
        from trailing: String,
        context: String
    ) -> Result<TrailingAction, ShellError> {
        let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success(.none)
        }

        if trimmed.hasPrefix("|") {
            let tail = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else {
                return .failure(.parserError("\(context): expected command after '|'"))
            }
            return .success(.pipeline(tail))
        }

        switch parseRedirections(from: trimmed, context: context) {
        case let .success(redirections):
            return .success(.redirections(redirections))
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func parseRedirections(
        from trailing: String,
        context: String
    ) -> Result<[Redirection], ShellError> {
        let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success([])
        }

        do {
            let parsed = try ShellParser.parse("true \(trimmed)")
            guard parsed.segments.count == 1,
                  let segment = parsed.segments.first,
                  segment.connector == nil,
                  segment.pipeline.count == 1,
                  !segment.runInBackground,
                  segment.pipeline[0].words.count == 1,
                  segment.pipeline[0].words[0].rawValue == "true" else {
                return .failure(
                    .parserError("\(context): unsupported trailing syntax")
                )
            }
            return .success(segment.pipeline[0].redirections)
        } catch let shellError as ShellError {
            return .failure(shellError)
        } catch {
            return .failure(.parserError("\(error)"))
        }
    }

    private static func trimmingTrailingNewlines(from value: String) -> String {
        var output = value
        while output.hasSuffix("\n") {
            output.removeLast()
        }
        return output
    }

    private static func expandWord(
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

    private static func expandVariables(
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

    private static func skipWhitespace(
        in commandLine: String,
        index: inout String.Index
    ) {
        while index < commandLine.endIndex, commandLine[index].isWhitespace {
            index = commandLine.index(after: index)
        }
    }

    private static func readIdentifier(
        in commandLine: String,
        index: inout String.Index
    ) -> String? {
        guard index < commandLine.endIndex else {
            return nil
        }

        let first = commandLine[index]
        guard first == "_" || first.isLetter else {
            return nil
        }

        var value = String(first)
        index = commandLine.index(after: index)
        while index < commandLine.endIndex,
              isIdentifierCharacter(commandLine[index]) {
            value.append(commandLine[index])
            index = commandLine.index(after: index)
        }
        return value
    }

    private static func consumeLiteral(
        _ literal: Character,
        in commandLine: String,
        index: inout String.Index
    ) -> Bool {
        guard index < commandLine.endIndex,
              commandLine[index] == literal else {
            return false
        }
        index = commandLine.index(after: index)
        return true
    }

    private static func consumeKeyword(
        _ keyword: String,
        in commandLine: String,
        index: inout String.Index
    ) -> Bool {
        guard commandLine[index...].hasPrefix(keyword) else {
            return false
        }

        let end = commandLine.index(index, offsetBy: keyword.count)
        if end < commandLine.endIndex,
           isIdentifierCharacter(commandLine[end]) {
            return false
        }

        index = end
        return true
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

}
