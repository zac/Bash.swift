import Foundation

struct ShellExecutionResult: Sendable {
    var result: CommandResult
    var currentDirectory: String
    var environment: [String: String]
}

enum ShellExecutor {
    static func execute(
        parsedLine: ParsedLine,
        stdin: Data,
        filesystem: any ShellFilesystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> ShellExecutionResult {
        var currentDirectory = currentDirectory
        var environment = environment

        guard !parsedLine.segments.isEmpty else {
            return ShellExecutionResult(
                result: CommandResult(stdout: Data(), stderr: Data(), exitCode: 0),
                currentDirectory: currentDirectory,
                environment: environment
            )
        }

        var aggregateOut = Data()
        var aggregateErr = Data()
        var lastExitCode: Int32 = 0

        for segment in parsedLine.segments {
            if shouldSkipSegment(connector: segment.connector, previousExitCode: lastExitCode) {
                continue
            }

            if segment.runInBackground {
                let rendered = renderSegment(segment)
                if let jobControl {
                    let backgroundDirectory = currentDirectory
                    let backgroundEnvironment = environment
                    let backgroundHistory = history
                    let backgroundRegistry = commandRegistry
                    let backgroundFilesystem = filesystem
                    let backgroundInput = stdin
                    let backgroundEnableGlobbing = enableGlobbing
                    let backgroundSecretPolicy = secretPolicy
                    let backgroundSecretResolver = secretResolver
                    let backgroundRedactor = secretOutputRedactor

                    let launch = await jobControl.launchBackgroundJob(commandLine: rendered) {
                        var isolatedDirectory = backgroundDirectory
                        var isolatedEnvironment = backgroundEnvironment
                        let localTracker = backgroundSecretPolicy == .off ? nil : SecretExposureTracker()

                        var result = await executePipeline(
                            commands: segment.pipeline,
                            initialInput: backgroundInput,
                            filesystem: backgroundFilesystem,
                            currentDirectory: &isolatedDirectory,
                            environment: &isolatedEnvironment,
                            history: backgroundHistory,
                            commandRegistry: backgroundRegistry,
                            shellFunctions: shellFunctions,
                            enableGlobbing: backgroundEnableGlobbing,
                            jobControl: nil,
                            secretPolicy: backgroundSecretPolicy,
                            secretResolver: backgroundSecretResolver,
                            secretTracker: localTracker,
                            secretOutputRedactor: backgroundRedactor
                        )

                        if let localTracker {
                            result = await redactCommandResult(
                                result,
                                secretTracker: localTracker,
                                secretOutputRedactor: backgroundRedactor
                            )
                        }

                        return result
                    }

                    environment["!"] = String(launch.pid)
                    aggregateOut.append(Data("[\(launch.jobID)] \(launch.pid)\n".utf8))
                    lastExitCode = 0
                    continue
                }
            }

            let segmentResult = await executePipeline(
                commands: segment.pipeline,
                initialInput: stdin,
                filesystem: filesystem,
                currentDirectory: &currentDirectory,
                environment: &environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                jobControl: jobControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )

            aggregateOut.append(segmentResult.stdout)
            aggregateErr.append(segmentResult.stderr)
            lastExitCode = segmentResult.exitCode
        }

        return ShellExecutionResult(
            result: CommandResult(stdout: aggregateOut, stderr: aggregateErr, exitCode: lastExitCode),
            currentDirectory: currentDirectory,
            environment: environment
        )
    }

    private static func shouldSkipSegment(connector: ChainOperator?, previousExitCode: Int32) -> Bool {
        guard let connector else {
            return false
        }

        switch connector {
        case .sequence:
            return false
        case .and:
            return previousExitCode != 0
        case .or:
            return previousExitCode == 0
        }
    }

    private static func executePipeline(
        commands: [ParsedCommand],
        initialInput: Data,
        filesystem: any ShellFilesystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        var nextInput = initialInput
        var aggregateStderr = Data()
        var lastResult = CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)

        for command in commands {
            var commandResult = await executeSingleCommand(
                command,
                stdin: nextInput,
                filesystem: filesystem,
                currentDirectory: &currentDirectory,
                environment: &environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                jobControl: jobControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )

            aggregateStderr.append(commandResult.stderr)
            nextInput = commandResult.stdout
            commandResult.stderr = Data()
            lastResult = commandResult
        }

        lastResult.stderr = aggregateStderr
        return lastResult
    }

    private static func executeSingleCommand(
        _ command: ParsedCommand,
        stdin: Data,
        filesystem: any ShellFilesystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        var input = stdin
        var stderr = Data()

        for redirection in command.redirections where redirection.type == .stdin {
            guard let targetWord = redirection.target else { continue }
            let target = await firstExpansion(
                word: targetWord,
                filesystem: filesystem,
                currentDirectory: currentDirectory,
                environment: environment,
                enableGlobbing: enableGlobbing
            )

            do {
                input = try await filesystem.readFile(path: PathUtils.normalize(path: target, currentDirectory: currentDirectory))
            } catch {
                stderr.append(Data("\(target): \(error)\n".utf8))
                return CommandResult(stdout: Data(), stderr: stderr, exitCode: 1)
            }
        }

        let expandedWords = await expandWords(
            command.words,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            enableGlobbing: enableGlobbing
        )

        guard let commandName = expandedWords.first else {
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }

        let commandArgs = Array(expandedWords.dropFirst())

        var result: CommandResult
        if commandArgs.isEmpty, let assignment = parseAssignment(commandName) {
            environment[assignment.name] = assignment.value
            result = CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        } else if let implementation = resolveCommand(named: commandName, registry: commandRegistry) {
            var context = CommandContext(
                commandName: commandName,
                arguments: commandArgs,
                filesystem: filesystem,
                enableGlobbing: enableGlobbing,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                availableCommands: commandRegistry.keys.sorted(),
                commandRegistry: commandRegistry,
                history: history,
                currentDirectory: currentDirectory,
                environment: environment,
                stdin: input,
                secretTracker: secretTracker,
                jobControl: jobControl
            )

            let exitCode = await implementation.runCommand(&context, commandArgs)
            result = CommandResult(
                stdout: context.stdout,
                stderr: context.stderr,
                exitCode: exitCode
            )
            currentDirectory = context.currentDirectory
            environment = context.environment
        } else if let functionBody = shellFunctions[commandName] {
            result = await executeShellFunction(
                functionBody,
                functionArguments: commandArgs,
                stdin: input,
                filesystem: filesystem,
                currentDirectory: &currentDirectory,
                environment: &environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                jobControl: jobControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )
        } else {
            let message = "\(commandName): command not found\n"
            return CommandResult(stdout: Data(), stderr: Data(message.utf8), exitCode: 127)
        }

        for redirection in command.redirections where redirection.type != .stdin {
            switch redirection.type {
            case .stdoutTruncate, .stdoutAppend:
                guard let targetWord = redirection.target else { continue }
                let target = await firstExpansion(
                    word: targetWord,
                    filesystem: filesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    enableGlobbing: enableGlobbing
                )

                do {
                    let path = PathUtils.normalize(path: target, currentDirectory: currentDirectory)
                    let redactedOutput = await redactForExternalOutput(
                        result.stdout,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    try await filesystem.writeFile(
                        path: path,
                        data: redactedOutput,
                        append: redirection.type == .stdoutAppend
                    )
                    result.stdout.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            case .stderrTruncate, .stderrAppend:
                guard let targetWord = redirection.target else { continue }
                let target = await firstExpansion(
                    word: targetWord,
                    filesystem: filesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    enableGlobbing: enableGlobbing
                )

                do {
                    let path = PathUtils.normalize(path: target, currentDirectory: currentDirectory)
                    let redactedStderr = await redactForExternalOutput(
                        result.stderr,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    try await filesystem.writeFile(
                        path: path,
                        data: redactedStderr,
                        append: redirection.type == .stderrAppend
                    )
                    result.stderr.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            case .stderrToStdout:
                result.stdout.append(result.stderr)
                result.stderr.removeAll(keepingCapacity: true)
            case .stdoutAndErrTruncate, .stdoutAndErrAppend:
                guard let targetWord = redirection.target else { continue }
                let target = await firstExpansion(
                    word: targetWord,
                    filesystem: filesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    enableGlobbing: enableGlobbing
                )

                do {
                    let path = PathUtils.normalize(path: target, currentDirectory: currentDirectory)
                    let redactedStdout = await redactForExternalOutput(
                        result.stdout,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    let redactedStderr = await redactForExternalOutput(
                        result.stderr,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    var combined = Data()
                    combined.append(redactedStdout)
                    combined.append(redactedStderr)
                    try await filesystem.writeFile(
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
            case .stdin:
                continue
            }
        }

        return result
    }

    private static func executeShellFunction(
        _ body: String,
        functionArguments: [String],
        stdin: Data,
        filesystem: any ShellFilesystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        let parsedBody: ParsedLine
        do {
            parsedBody = try ShellParser.parse(body)
        } catch {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(error)\n".utf8),
                exitCode: 2
            )
        }

        let savedPositional = snapshotPositionalParameters(from: environment)
        applyPositionalParameters(functionArguments, to: &environment)

        let execution = await execute(
            parsedLine: parsedBody,
            stdin: stdin,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            jobControl: jobControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )

        currentDirectory = execution.currentDirectory
        environment = restorePositionalParameters(
            in: execution.environment,
            snapshot: savedPositional
        )
        return execution.result
    }

    private static func renderSegment(_ segment: ParsedSegment) -> String {
        segment.pipeline.map(renderCommand).joined(separator: " | ")
    }

    private static func renderCommand(_ command: ParsedCommand) -> String {
        var parts = command.words.map(\.rawValue)

        for redirection in command.redirections {
            switch redirection.type {
            case .stdin:
                parts.append("<")
            case .stdoutTruncate:
                parts.append(">")
            case .stdoutAppend:
                parts.append(">>")
            case .stderrTruncate:
                parts.append("2>")
            case .stderrAppend:
                parts.append("2>>")
            case .stderrToStdout:
                parts.append("2>&1")
            case .stdoutAndErrTruncate:
                parts.append("&>")
            case .stdoutAndErrAppend:
                parts.append("&>>")
            }

            if let target = redirection.target {
                parts.append(target.rawValue)
            }
        }

        return parts.joined(separator: " ")
    }

    private static func resolveCommand(named commandName: String, registry: [String: AnyBuiltinCommand]) -> AnyBuiltinCommand? {
        if commandName.hasPrefix("/") {
            let base = PathUtils.basename(commandName)
            return registry[base]
        }

        if let direct = registry[commandName] {
            return direct
        }

        if commandName.contains("/") {
            return registry[PathUtils.basename(commandName)]
        }

        return nil
    }

    private static func parseAssignment(_ word: String) -> (name: String, value: String)? {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else {
            return nil
        }

        let name = String(word[..<equals])
        guard isValidIdentifier(name) else {
            return nil
        }

        let valueStart = word.index(after: equals)
        let value = String(word[valueStart...])
        return (name: name, value: value)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func snapshotPositionalParameters(from environment: [String: String]) -> [String: String] {
        environment.filter { isPositionalParameterKey($0.key) }
    }

    private static func applyPositionalParameters(_ args: [String], to environment: inout [String: String]) {
        for key in Array(environment.keys) where isPositionalParameterKey(key) {
            environment.removeValue(forKey: key)
        }

        environment["#"] = String(args.count)
        environment["@"] = args.joined(separator: " ")
        environment["*"] = args.joined(separator: " ")
        for (offset, value) in args.enumerated() {
            environment[String(offset + 1)] = value
        }
    }

    private static func restorePositionalParameters(
        in environment: [String: String],
        snapshot: [String: String]
    ) -> [String: String] {
        var output = environment
        for key in Array(output.keys) where isPositionalParameterKey(key) {
            output.removeValue(forKey: key)
        }
        output.merge(snapshot) { _, rhs in rhs }
        return output
    }

    private static func isPositionalParameterKey(_ key: String) -> Bool {
        if key == "#" || key == "@" || key == "*" {
            return true
        }
        return !key.isEmpty && key.allSatisfy(\.isNumber)
    }

    private static func redactCommandResult(
        _ result: CommandResult,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        guard let secretTracker else {
            return result
        }

        let replacements = await secretTracker.snapshot()
        guard !replacements.isEmpty else {
            return result
        }

        return CommandResult(
            stdout: secretOutputRedactor.redact(data: result.stdout, replacements: replacements),
            stderr: secretOutputRedactor.redact(data: result.stderr, replacements: replacements),
            exitCode: result.exitCode
        )
    }

    private static func expandWords(
        _ words: [ShellWord],
        filesystem: any ShellFilesystem,
        currentDirectory: String,
        environment: [String: String],
        enableGlobbing: Bool
    ) async -> [String] {
        var expanded: [String] = []

        for word in words {
            let results = await expandWord(
                word,
                filesystem: filesystem,
                currentDirectory: currentDirectory,
                environment: environment,
                enableGlobbing: enableGlobbing
            )
            expanded.append(contentsOf: results)
        }

        return expanded
    }

    private static func firstExpansion(
        word: ShellWord,
        filesystem: any ShellFilesystem,
        currentDirectory: String,
        environment: [String: String],
        enableGlobbing: Bool
    ) async -> String {
        let expanded = await expandWord(
            word,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            enableGlobbing: enableGlobbing
        )
        return expanded.first ?? ""
    }

    private static func expandWord(
        _ word: ShellWord,
        filesystem: any ShellFilesystem,
        currentDirectory: String,
        environment: [String: String],
        enableGlobbing: Bool
    ) async -> [String] {
        var combined = ""

        for part in word.parts {
            switch part.quote {
            case .single:
                combined += part.text
            case .none, .double:
                combined += expandVariables(in: part.text, environment: environment)
            }
        }

        guard enableGlobbing, word.hasUnquotedWildcard, PathUtils.containsGlob(combined) else {
            return [combined]
        }

        do {
            let matches = try await filesystem.glob(pattern: combined, currentDirectory: currentDirectory)
            return matches.isEmpty ? [combined] : matches
        } catch {
            return [combined]
        }
    }

    private static func expandVariables(in string: String, environment: [String: String]) -> String {
        var result = ""
        var index = string.startIndex

        func readIdentifier(startingAt start: String.Index) -> (String, String.Index) {
            var i = start
            var value = ""
            while i < string.endIndex {
                let char = string[i]
                if char.isLetter || char.isNumber || char == "_" {
                    value.append(char)
                    i = string.index(after: i)
                } else {
                    break
                }
            }
            return (value, i)
        }

        while index < string.endIndex {
            let char = string[index]
            guard char == "$" else {
                result.append(char)
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

            if string[next] == "(" {
                let maybeSecondOpen = string.index(after: next)
                if maybeSecondOpen < string.endIndex, string[maybeSecondOpen] == "(",
                   let capture = captureArithmeticExpansion(
                       in: string,
                       secondOpen: maybeSecondOpen
                   ) {
                    let evaluated = evaluateArithmeticExpression(
                        capture.expression,
                        environment: environment
                    ) ?? 0
                    result += String(evaluated)
                    index = capture.endIndex
                    continue
                }
            }

            if string[next] == "{" {
                guard let close = string[next...].firstIndex(of: "}") else {
                    result.append("$")
                    index = next
                    continue
                }

                let contentStart = string.index(after: next)
                let content = String(string[contentStart..<close])

                if let range = content.range(of: ":-") {
                    let key = String(content[..<range.lowerBound])
                    let fallback = String(content[range.upperBound...])
                    let value = environment[key]
                    if let value, !value.isEmpty {
                        result += value
                    } else {
                        result += fallback
                    }
                } else {
                    result += environment[content] ?? ""
                }

                index = string.index(after: close)
                continue
            }

            let (key, end) = readIdentifier(startingAt: next)
            if key.isEmpty {
                result.append("$")
                index = next
            } else {
                result += environment[key] ?? ""
                index = end
            }
        }

        return result
    }

    private static func captureArithmeticExpansion(
        in string: String,
        secondOpen: String.Index
    ) -> (expression: String, endIndex: String.Index)? {
        var depth = 1
        var cursor = string.index(after: secondOpen)
        let expressionStart = cursor

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
                        let expression = String(string[expressionStart..<cursor])
                        return (
                            expression: expression,
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

    private static func evaluateArithmeticExpression(
        _ raw: String,
        environment: [String: String]
    ) -> Int? {
        enum Token {
            case number(Int)
            case op(Character)
            case lparen
            case rparen
        }

        func isIdentifierStart(_ character: Character) -> Bool {
            character == "_" || character.isLetter
        }

        func isIdentifierBody(_ character: Character) -> Bool {
            character == "_" || character.isLetter || character.isNumber
        }

        let chars = Array(raw)
        var tokens: [Token] = []
        var index = 0

        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                index += 1
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

            if "+-*/%".contains(char) {
                tokens.append(.op(char))
                index += 1
                continue
            }

            if char.isNumber ||
                (char == "-" && index + 1 < chars.count && chars[index + 1].isNumber) {
                var value = String(char)
                index += 1
                while index < chars.count, chars[index].isNumber {
                    value.append(chars[index])
                    index += 1
                }
                guard let intValue = Int(value) else {
                    return nil
                }
                tokens.append(.number(intValue))
                continue
            }

            if isIdentifierStart(char) {
                var name = String(char)
                index += 1
                while index < chars.count, isIdentifierBody(chars[index]) {
                    name.append(chars[index])
                    index += 1
                }
                let intValue = Int(environment[name] ?? "") ?? 0
                tokens.append(.number(intValue))
                continue
            }

            return nil
        }

        var cursor = 0

        func parseExpression() -> Int? {
            guard var value = parseTerm() else {
                return nil
            }

            while cursor < tokens.count {
                guard case let .op(op) = tokens[cursor], op == "+" || op == "-" else {
                    break
                }
                cursor += 1
                guard let rhs = parseTerm() else {
                    return nil
                }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        func parseTerm() -> Int? {
            guard var value = parseFactor() else {
                return nil
            }

            while cursor < tokens.count {
                guard case let .op(op) = tokens[cursor], op == "*" || op == "/" || op == "%" else {
                    break
                }
                cursor += 1
                guard let rhs = parseFactor() else {
                    return nil
                }

                switch op {
                case "*":
                    value *= rhs
                case "/":
                    if rhs == 0 {
                        return nil
                    }
                    value /= rhs
                case "%":
                    if rhs == 0 {
                        return nil
                    }
                    value %= rhs
                default:
                    return nil
                }
            }
            return value
        }

        func parseFactor() -> Int? {
            guard cursor < tokens.count else {
                return nil
            }

            switch tokens[cursor] {
            case let .number(value):
                cursor += 1
                return value
            case .lparen:
                cursor += 1
                guard let value = parseExpression() else {
                    return nil
                }
                guard cursor < tokens.count, case .rparen = tokens[cursor] else {
                    return nil
                }
                cursor += 1
                return value
            case .rparen:
                return nil
            case .op(let op):
                if op == "-" {
                    cursor += 1
                    guard let value = parseFactor() else {
                        return nil
                    }
                    return -value
                }
                return nil
            }
        }

        guard let value = parseExpression(), cursor == tokens.count else {
            return nil
        }
        return value
    }

    private static func redactForExternalOutput(
        _ data: Data,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> Data {
        guard let secretTracker else {
            return data
        }

        let replacements = await secretTracker.snapshot()
        guard !replacements.isEmpty else {
            return data
        }

        return secretOutputRedactor.redact(
            data: data,
            replacements: replacements
        )
    }
}
