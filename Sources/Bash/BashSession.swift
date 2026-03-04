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

        do {
            let parsed = try ShellParser.parse(executableLine)
            let filesystem = filesystemStore
            let startDirectory = currentDirectoryStore
            let startEnvironment = environmentStore
            let history = historyStore
            let registry = commandRegistry
            let shellFunctions = shellFunctionStore
            let enableGlobbing = options.enableGlobbing
            let secretPolicy = options.secretPolicy
            let secretResolver = options.secretResolver
            let secretOutputRedactor = options.secretOutputRedactor
            let secretTracker = secretPolicy == .off ? nil : SecretExposureTracker()

            let execution = await ShellExecutor.execute(
                parsedLine: parsed,
                stdin: stdin,
                filesystem: filesystem,
                currentDirectory: startDirectory,
                environment: startEnvironment,
                history: history,
                commandRegistry: registry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                jobControl: jobManager,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )

            var result = execution.result
            if let secretTracker {
                let replacements = await secretTracker.snapshot()
                if !replacements.isEmpty {
                    result.stdout = secretOutputRedactor.redact(
                        data: result.stdout,
                        replacements: replacements
                    )
                    result.stderr = secretOutputRedactor.redact(
                        data: result.stderr,
                        replacements: replacements
                    )
                }
            }

            if !substitution.stderr.isEmpty {
                var merged = substitution.stderr
                merged.append(result.stderr)
                result.stderr = merged
            }

            currentDirectoryStore = execution.currentDirectory
            environmentStore = execution.environment
            environmentStore["PWD"] = currentDirectoryStore
            return result
        } catch {
            var stderr = substitution.stderr
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(
                stdout: Data(),
                stderr: stderr,
                exitCode: 2
            )
        }
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
        var trailingRedirections: [Redirection]
    }

    private enum SimpleForLoopParseResult {
        case notForLoop
        case success(SimpleForLoop)
        case failure(ShellError)
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
            await applyRedirections(loop.trailingRedirections, to: &result)

            if !prefixedStderr.isEmpty {
                var merged = prefixedStderr
                merged.append(result.stderr)
                result.stderr = merged
            }

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
        guard let valuesMarker = Self.findSemicolonKeyword(
            "do",
            in: commandLine,
            from: index
        ) else {
            return .failure(.parserError("for: expected '; do'"))
        }

        let rawValues = String(commandLine[index..<valuesMarker.semicolonIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let values: [String]
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
        if values.isEmpty {
            return .failure(.parserError("for: expected one or more values"))
        }

        let bodyStart = valuesMarker.afterKeywordIndex
        guard let bodyMarker = Self.findSemicolonKeyword(
            "done",
            in: commandLine,
            from: bodyStart
        ) else {
            return .failure(.parserError("for: expected '; done'"))
        }

        let body = String(commandLine[bodyStart..<bodyMarker.semicolonIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return .failure(.parserError("for: expected non-empty loop body"))
        }

        let tail = String(commandLine[bodyMarker.afterKeywordIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redirectionsResult = Self.parseRedirections(from: tail)
        let redirections: [Redirection]
        switch redirectionsResult {
        case let .success(value):
            redirections = value
        case let .failure(error):
            return .failure(error)
        }

        return .success(
            SimpleForLoop(
                variableName: variableName,
                values: values,
                body: body,
                trailingRedirections: redirections
            )
        )
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

    private static func findSemicolonKeyword(
        _ keyword: String,
        in commandLine: String,
        from startIndex: String.Index
    ) -> (semicolonIndex: String.Index, afterKeywordIndex: String.Index)? {
        var quote: QuoteKind = .none
        var index = startIndex

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

            if quote == .none, character == ";" {
                var cursor = commandLine.index(after: index)
                Self.skipWhitespace(in: commandLine, index: &cursor)
                guard cursor < commandLine.endIndex else {
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

                return (semicolonIndex: index, afterKeywordIndex: afterKeyword)
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

    private static func parseRedirections(
        from trailing: String
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
                    .parserError("for: unsupported trailing syntax")
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
