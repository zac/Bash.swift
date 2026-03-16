import Foundation

public final actor BashSession {
    private let filesystemStore: any ShellFilesystem
    private let options: SessionOptions
    private let jobManager: ShellJobManager
    private let permissionAuthorizer: PermissionAuthorizer

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
        await run(commandLine, options: RunOptions(stdin: stdin))
    }

    public func run(_ commandLine: String, options: RunOptions) async -> CommandResult {
        let usesTemporaryState = options.currentDirectory != nil
            || !options.environment.isEmpty
            || options.replaceEnvironment
        guard usesTemporaryState else {
            return await runPersistingState(commandLine, stdin: options.stdin)
        }

        let savedCurrentDirectory = currentDirectoryStore
        let savedEnvironment = environmentStore
        let savedFunctions = shellFunctionStore

        if let overrideDirectory = options.currentDirectory {
            do {
                try PathUtils.validate(overrideDirectory)
            } catch {
                return CommandResult(
                    stdout: Data(),
                    stderr: Data("\(error)\n".utf8),
                    exitCode: 2
                )
            }
        }

        if options.replaceEnvironment {
            environmentStore = [:]
        }

        if let overrideDirectory = options.currentDirectory {
            currentDirectoryStore = PathUtils.normalize(
                path: overrideDirectory,
                currentDirectory: savedCurrentDirectory
            )
            if options.environment["PWD"] == nil {
                environmentStore["PWD"] = currentDirectoryStore
            }
        }

        if !options.environment.isEmpty {
            environmentStore.merge(options.environment) { _, rhs in rhs }
        }

        let result = await runPersistingState(commandLine, stdin: options.stdin)

        currentDirectoryStore = savedCurrentDirectory
        environmentStore = savedEnvironment
        shellFunctionStore = savedFunctions
        return result
    }

    private func runPersistingState(_ commandLine: String, stdin: Data) async -> CommandResult {
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

        if let untilResult = await executeSimpleUntilLoopIfPresent(
            commandLine: executableLine,
            stdin: stdin,
            prefixedStderr: substitution.stderr
        ) {
            return untilResult
        }

        if let caseResult = await executeSimpleCaseBlockIfPresent(
            commandLine: executableLine,
            stdin: stdin,
            prefixedStderr: substitution.stderr
        ) {
            return caseResult
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
        permissionAuthorizer = PermissionAuthorizer(handler: options.permissionHandler)

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

    private struct PendingHereDocument {
        var delimiter: String
        var stripsLeadingTabs: Bool
    }

    private struct FunctionDefinitionParseOutcome {
        var remaining: String
        var error: ShellError?
    }

    private struct SimpleForLoop {
        enum Kind {
            case list(variableName: String, values: [String])
            case cStyle(initializer: String, condition: String, increment: String)
        }

        var kind: Kind
        var body: String
        var trailingAction: TrailingAction
    }

    private enum SimpleForLoopParseResult {
        case notForLoop
        case success(SimpleForLoop)
        case failure(ShellError)
    }

    private struct IfBranch {
        var condition: String
        var body: String
    }

    private struct SimpleIfBlock {
        var branches: [IfBranch]
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
        var isUntil: Bool
        var body: String
        var trailingAction: TrailingAction
    }

    private enum SimpleWhileLoopParseResult {
        case notWhileLoop
        case success(SimpleWhileLoop)
        case failure(ShellError)
    }

    private struct SimpleCaseArm {
        var patterns: [String]
        var body: String
    }

    private struct SimpleCaseBlock {
        var leadingCommands: String?
        var subject: String
        var arms: [SimpleCaseArm]
        var trailingAction: TrailingAction
    }

    private enum SimpleCaseBlockParseResult {
        case notCaseBlock
        case success(SimpleCaseBlock)
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
            permissionAuthorizer: permissionAuthorizer,
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
        var pendingHereDocuments: [PendingHereDocument] = []

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

            switch loop.kind {
            case let .list(variableName, values):
                for value in values {
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
                    if iterations > 10_000 {
                        combinedErr.append(Data("for: exceeded max iterations\n".utf8))
                        lastExitCode = 2
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

    private func executeSimpleWhileLoopIfPresent(
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

    private func executeSimpleUntilLoopIfPresent(
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

    private func executeSimpleConditionalLoopIfPresent(
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
                if iterations > 10_000 {
                    let loopName = loop.isUntil ? "until" : "while"
                    combinedErr.append(Data("\(loopName): exceeded max iterations\n".utf8))
                    lastExitCode = 2
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

    private func parseSimpleWhileLoop(_ commandLine: String) -> SimpleWhileLoopParseResult {
        parseSimpleConditionalLoop(
            commandLine,
            keyword: "while",
            isUntil: false
        )
    }

    private func parseSimpleUntilLoop(_ commandLine: String) -> SimpleWhileLoopParseResult {
        parseSimpleConditionalLoop(
            commandLine,
            keyword: "until",
            isUntil: true
        )
    }

    private func parseSimpleConditionalLoop(
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

    private func parseConditionalLoopClause(
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

    private func executeSimpleCaseBlockIfPresent(
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

    private func parseSimpleCaseBlock(_ commandLine: String) -> SimpleCaseBlockParseResult {
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

    private func parseCaseClause(
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

    private static func captureArithmeticExpansion(
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

    private static func captureHereDocumentDeclaration(
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

    private static func captureHereDocumentBodiesVerbatim(
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

    private static func stripLeadingTabs(from line: String) -> String {
        String(line.drop { $0 == "\t" })
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

    private static func findFirstDelimitedKeyword(
        _ keywords: [String],
        in commandLine: String,
        from startIndex: String.Index,
        end: String.Index? = nil
    ) -> (keyword: String, match: DelimitedKeywordMatch)? {
        var best: (keyword: String, match: DelimitedKeywordMatch)?
        for keyword in keywords {
            guard let match = findDelimitedKeyword(
                keyword,
                in: commandLine,
                from: startIndex,
                end: end
            ) else {
                continue
            }

            if let currentBest = best {
                if match.separatorIndex < currentBest.match.separatorIndex {
                    best = (keyword, match)
                }
            } else {
                best = (keyword, match)
            }
        }
        return best
    }

    private static func findKeywordTokenRange(
        _ keyword: String,
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

            if quote == .none, value[index...].hasPrefix(keyword) {
                let afterKeyword = value.index(index, offsetBy: keyword.count)
                let beforeBoundary: Bool
                if index == value.startIndex {
                    beforeBoundary = true
                } else {
                    let previous = value[value.index(before: index)]
                    beforeBoundary = isKeywordBoundaryCharacter(previous)
                }

                let afterBoundary: Bool
                if afterKeyword == value.endIndex {
                    afterBoundary = true
                } else {
                    afterBoundary = isKeywordBoundaryCharacter(value[afterKeyword])
                }

                if beforeBoundary, afterBoundary {
                    return index..<afterKeyword
                }
            }

            index = value.index(after: index)
        }

        return nil
    }

    private static func isKeywordBoundaryCharacter(_ character: Character) -> Bool {
        character.isWhitespace || character == ";" || character == "(" || character == ")"
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

    private static func parseCStyleForHeader(
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

    private static func captureBalancedDoubleParentheses(
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

    private static func splitCStyleForComponents(_ value: String) -> [String] {
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

    private func executeCStyleArithmeticStatement(_ statement: String) -> ShellError? {
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

    private static func parseCaseArms(_ rawArms: String) throws -> [SimpleCaseArm] {
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

    private static func evaluateCaseWord(
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

    private static func casePatternMatches(
        _ rawPattern: String,
        value: String,
        environment: [String: String]
    ) -> Bool {
        let expanded = evaluateCaseWord(rawPattern, environment: environment)
        guard let regex = try? NSRegularExpression(pattern: PathUtils.globToRegex(expanded)) else {
            return expanded == value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static func splitCasePatterns(_ value: String) -> [String] {
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

    private static func findUnquotedCharacter(
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

    private static func findUnquotedDoubleSemicolon(
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

    private static func isValidIdentifierName(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

}
