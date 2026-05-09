import Foundation

package struct ShellExecutionResult: Sendable {
    package var result: CommandResult
    package var currentDirectory: String
    package var environment: [String: String]
}

private struct TextExpansionOutcome: Sendable {
    var text: String
    var stderr: Data
    var error: ShellError?
    var failure: ExecutionFailure?
}

private struct WordExpansionOutcome: Sendable {
    var words: [String]
    var stderr: Data
    var error: ShellError?
    var failure: ExecutionFailure?
}

package enum ShellOptionKeys {
    package static let pipefail = "__BASHSWIFT_SHELLOPT_PIPEFAIL"
    package static let errexit = "__BASHSWIFT_SHELLOPT_ERREXIT"
    package static let nounset = "__BASHSWIFT_SHELLOPT_NOUNSET"
    package static let xtrace = "__BASHSWIFT_SHELLOPT_XTRACE"
}

package enum ShellInternalKeys {
    package static let exitRequested = "__BASHSWIFT_INTERNAL_EXIT_REQUESTED"
}

package enum ShellExecutor {
    package static func execute(
        parsedLine: ParsedLine,
        stdin: Data,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
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

        for (offset, segment) in parsedLine.segments.enumerated() {
            if let failure = await executionControl?.checkpoint() {
                lastExitCode = failure.exitCode
                aggregateErr.append(Data("\(failure.message)\n".utf8))
                break
            }

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
                            permissionAuthorizer: permissionAuthorizer,
                            executionControl: executionControl,
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
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )

            aggregateOut.append(segmentResult.stdout)
            aggregateErr.append(segmentResult.stderr)
            lastExitCode = segmentResult.exitCode

            if environment.removeValue(forKey: ShellInternalKeys.exitRequested) != nil {
                break
            }

            let nextConnector = parsedLine.segments.indices.contains(offset + 1)
                ? parsedLine.segments[offset + 1].connector
                : nil
            if shouldExitForErrexit(
                environment: environment,
                exitCode: lastExitCode,
                nextConnector: nextConnector
            ) {
                break
            }
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

    private static func shouldExitForErrexit(
        environment: [String: String],
        exitCode: Int32,
        nextConnector: ChainOperator?
    ) -> Bool {
        guard environment[ShellOptionKeys.errexit] == "1", exitCode != 0 else {
            return false
        }

        switch nextConnector {
        case .and, .or:
            return false
        case .sequence, nil:
            return true
        }
    }

    private static func executePipeline(
        commands: [ParsedCommand],
        initialInput: Data,
        filesystem: any FileSystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        var nextInput = initialInput
        var aggregateStderr = Data()
        var lastResult = CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        var pipefailExitCode: Int32 = 0

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
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )

            aggregateStderr.append(commandResult.stderr)
            if commandResult.exitCode != 0 {
                pipefailExitCode = commandResult.exitCode
            }
            nextInput = commandResult.stdout
            commandResult.stderr = Data()
            lastResult = commandResult
        }

        lastResult.stderr = aggregateStderr
        if environment[ShellOptionKeys.pipefail] == "1", pipefailExitCode != 0 {
            lastResult.exitCode = pipefailExitCode
        }
        return lastResult
    }

    private static func executeSingleCommand(
        _ command: ParsedCommand,
        stdin: Data,
        filesystem: any FileSystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        if let failure = await executionControl?.checkpoint() {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(failure.message)\n".utf8),
                exitCode: failure.exitCode
            )
        }

        let baseFilesystem = ShellPermissionedFileSystem.unwrap(filesystem)
        let initialCommandName = command.words.first?.rawValue.isEmpty == false
            ? command.words.first!.rawValue
            : "shell"
        let expansionFilesystem = ShellPermissionedFileSystem(
            base: baseFilesystem,
            commandName: initialCommandName,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl
        )

        var input = stdin
        var stderr = Data()

        for redirection in command.redirections where redirection.type == .stdin {
            if let hereDocument = redirection.hereDocument {
                let expandedHereDocument = await expandHereDocumentBody(
                    hereDocument,
                    filesystem: expansionFilesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    history: history,
                    commandRegistry: commandRegistry,
                    shellFunctions: shellFunctions,
                    enableGlobbing: enableGlobbing,
                    permissionAuthorizer: permissionAuthorizer,
                    executionControl: executionControl,
                    secretPolicy: secretPolicy,
                    secretResolver: secretResolver,
                    secretTracker: secretTracker,
                    secretOutputRedactor: secretOutputRedactor
                )
                stderr.append(expandedHereDocument.stderr)
                if let failure = expandedHereDocument.failure {
                    return CommandResult(stdout: Data(), stderr: stderr, exitCode: failure.exitCode)
                }
                if let error = expandedHereDocument.error {
                    stderr.append(Data("\(error)\n".utf8))
                    return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
                }
                input = Data(expandedHereDocument.text.utf8)
                continue
            }

            guard let targetWord = redirection.target else { continue }
            let targetExpansion = await firstExpansion(
                word: targetWord,
                filesystem: expansionFilesystem,
                currentDirectory: currentDirectory,
                environment: environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )
            stderr.append(targetExpansion.stderr)
            if let failure = targetExpansion.failure {
                return CommandResult(stdout: Data(), stderr: stderr, exitCode: failure.exitCode)
            }
            if let error = targetExpansion.error {
                stderr.append(Data("\(error)\n".utf8))
                return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
            }
            let target = targetExpansion.text

            do {
                input = try await expansionFilesystem.readFile(
                    path: WorkspacePath(normalizing: target, relativeTo: WorkspacePath(normalizing: currentDirectory))
                )
            } catch {
                stderr.append(Data("\(target): \(error)\n".utf8))
                return CommandResult(stdout: Data(), stderr: stderr, exitCode: 1)
            }
        }

        let wordExpansion = await expandWords(
            command.words,
            filesystem: expansionFilesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )
        stderr.append(wordExpansion.stderr)
        if let failure = wordExpansion.failure {
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: failure.exitCode)
        }
        if let error = wordExpansion.error {
            stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 2)
        }
        let expandedWords = wordExpansion.words

        guard !expandedWords.isEmpty else {
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 0)
        }

        var commandWordIndex = 0
        var scopedAssignments: [(name: String, previousValue: String?)] = []
        while commandWordIndex < expandedWords.count,
              let assignment = parseAssignment(expandedWords[commandWordIndex]) {
            scopedAssignments.append((name: assignment.name, previousValue: environment[assignment.name]))
            environment[assignment.name] = assignment.value
            commandWordIndex += 1
        }

        guard commandWordIndex < expandedWords.count else {
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 0)
        }

        let commandName = expandedWords[commandWordIndex]
        let commandArgs = Array(expandedWords.dropFirst(commandWordIndex + 1))
        let commandFilesystem = ShellPermissionedFileSystem(
            base: baseFilesystem,
            commandName: commandName,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl
        )

        func restoreScopedAssignments() {
            for assignment in scopedAssignments.reversed() {
                if let previousValue = assignment.previousValue {
                    environment[assignment.name] = previousValue
                } else {
                    environment.removeValue(forKey: assignment.name)
                }
            }
        }

        var result: CommandResult
        if commandName == "local" {
            result = executeLocalBuiltin(commandArgs, environment: &environment)
        } else if commandName == "source" || commandName == "." {
            result = await executeSourceBuiltin(
                commandName: commandName,
                args: commandArgs,
                stdin: input,
                filesystem: commandFilesystem,
                currentDirectory: &currentDirectory,
                environment: &environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                jobControl: jobControl,
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )
        } else if let implementation = resolveCommand(named: commandName, registry: commandRegistry) {
            if let failure = await executionControl?.recordCommandExecution(commandName: commandName) {
                restoreScopedAssignments()
                stderr.append(Data("\(failure.message)\n".utf8))
                return CommandResult(
                    stdout: Data(),
                    stderr: stderr,
                    exitCode: failure.exitCode
                )
            }

            var context = CommandContext(
                commandName: commandName,
                arguments: commandArgs,
                filesystem: commandFilesystem,
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
                jobControl: jobControl,
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl
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
                filesystem: baseFilesystem,
                currentDirectory: &currentDirectory,
                environment: &environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                jobControl: jobControl,
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )
        } else {
            restoreScopedAssignments()
            stderr.append(Data("\(commandName): command not found\n".utf8))
            return CommandResult(stdout: Data(), stderr: stderr, exitCode: 127)
        }

        restoreScopedAssignments()
        if !stderr.isEmpty {
            stderr.append(result.stderr)
            result.stderr = stderr
        }

        for redirection in command.redirections where redirection.type != .stdin {
            switch redirection.type {
            case .stdoutTruncate, .stdoutAppend:
                guard let targetWord = redirection.target else { continue }
                let targetExpansion = await firstExpansion(
                    word: targetWord,
                    filesystem: commandFilesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    history: history,
                    commandRegistry: commandRegistry,
                    shellFunctions: shellFunctions,
                    enableGlobbing: enableGlobbing,
                    permissionAuthorizer: permissionAuthorizer,
                    executionControl: executionControl,
                    secretPolicy: secretPolicy,
                    secretResolver: secretResolver,
                    secretTracker: secretTracker,
                    secretOutputRedactor: secretOutputRedactor
                )
                if let expansionFailure = applyRedirectionExpansionFailure(targetExpansion, to: &result) {
                    return expansionFailure
                }
                let target = targetExpansion.text

                do {
                    let path = WorkspacePath(
                        normalizing: target,
                        relativeTo: WorkspacePath(normalizing: currentDirectory)
                    )
                    try await commandFilesystem.writeFile(
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
                let targetExpansion = await firstExpansion(
                    word: targetWord,
                    filesystem: commandFilesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    history: history,
                    commandRegistry: commandRegistry,
                    shellFunctions: shellFunctions,
                    enableGlobbing: enableGlobbing,
                    permissionAuthorizer: permissionAuthorizer,
                    executionControl: executionControl,
                    secretPolicy: secretPolicy,
                    secretResolver: secretResolver,
                    secretTracker: secretTracker,
                    secretOutputRedactor: secretOutputRedactor
                )
                if let expansionFailure = applyRedirectionExpansionFailure(targetExpansion, to: &result) {
                    return expansionFailure
                }
                let target = targetExpansion.text

                do {
                    let path = WorkspacePath(
                        normalizing: target,
                        relativeTo: WorkspacePath(normalizing: currentDirectory)
                    )
                    try await commandFilesystem.writeFile(
                        path: path,
                        data: result.stderr,
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
                let targetExpansion = await firstExpansion(
                    word: targetWord,
                    filesystem: commandFilesystem,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    history: history,
                    commandRegistry: commandRegistry,
                    shellFunctions: shellFunctions,
                    enableGlobbing: enableGlobbing,
                    permissionAuthorizer: permissionAuthorizer,
                    executionControl: executionControl,
                    secretPolicy: secretPolicy,
                    secretResolver: secretResolver,
                    secretTracker: secretTracker,
                    secretOutputRedactor: secretOutputRedactor
                )
                if let expansionFailure = applyRedirectionExpansionFailure(targetExpansion, to: &result) {
                    return expansionFailure
                }
                let target = targetExpansion.text

                do {
                    let path = WorkspacePath(
                        normalizing: target,
                        relativeTo: WorkspacePath(normalizing: currentDirectory)
                    )
                    var combined = Data()
                    combined.append(result.stdout)
                    combined.append(result.stderr)
                    try await commandFilesystem.writeFile(
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
        filesystem: any FileSystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
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

        if let failure = await executionControl?.pushFunction() {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(failure.message)\n".utf8),
                exitCode: failure.exitCode
            )
        }

        let savedEnvironment = environment
        let savedPositional = snapshotPositionalParameters(from: environment)
        let previousDepth = Int(environment[functionDepthKey] ?? "0") ?? 0
        let currentDepth = previousDepth + 1
        let localBindingsKey = localBindingsKey(for: currentDepth)

        environment[functionDepthKey] = String(currentDepth)
        environment[localBindingsKey] = ""
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
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
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

        restoreLocalBindings(
            markerKey: localBindingsKey,
            savedEnvironment: savedEnvironment,
            environment: &environment
        )

        if previousDepth == 0 {
            environment.removeValue(forKey: functionDepthKey)
        } else {
            environment[functionDepthKey] = String(previousDepth)
        }

        await executionControl?.popFunction()

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
                if let hereDocument = redirection.hereDocument {
                    let operatorToken = hereDocument.stripsLeadingTabs ? "<<-" : "<<"
                    parts.append("\(operatorToken)\(hereDocument.delimiter)")
                } else {
                    parts.append("<")
                }
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
            let base = WorkspacePath.basename(commandName)
            return registry[base]
        }

        if let direct = registry[commandName] {
            return direct
        }

        if commandName.contains("/") {
            return registry[WorkspacePath.basename(commandName)]
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

    private static let functionDepthKey = "__BASHSWIFT_INTERNAL_FUNCTION_DEPTH"
    private static let localBindingsPrefix = "__BASHSWIFT_INTERNAL_LOCAL_KEYS_"

    private static func localBindingsKey(for depth: Int) -> String {
        "\(localBindingsPrefix)\(depth)"
    }

    private static func executeLocalBuiltin(
        _ args: [String],
        environment: inout [String: String]
    ) -> CommandResult {
        let depth = Int(environment[functionDepthKey] ?? "0") ?? 0
        guard depth > 0 else {
            return CommandResult(
                stdout: Data(),
                stderr: Data("local: can only be used in a function\n".utf8),
                exitCode: 1
            )
        }

        guard !args.isEmpty else {
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }

        let markerKey = localBindingsKey(for: depth)
        var localNames = environment[markerKey]?
            .split(separator: ",")
            .map(String.init) ?? []
        var seenNames = Set(localNames)

        for argument in args {
            if let assignment = parseAssignment(argument) {
                guard isValidIdentifier(assignment.name) else {
                    return CommandResult(
                        stdout: Data(),
                        stderr: Data("local: invalid identifier '\(assignment.name)'\n".utf8),
                        exitCode: 1
                    )
                }
                if seenNames.insert(assignment.name).inserted {
                    localNames.append(assignment.name)
                }
                environment[assignment.name] = assignment.value
                continue
            }

            guard isValidIdentifier(argument) else {
                return CommandResult(
                    stdout: Data(),
                    stderr: Data("local: invalid identifier '\(argument)'\n".utf8),
                    exitCode: 1
                )
            }

            if seenNames.insert(argument).inserted {
                localNames.append(argument)
            }
            if environment[argument] == nil {
                environment[argument] = ""
            }
        }

        environment[markerKey] = localNames.joined(separator: ",")
        return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }

    private static func restoreLocalBindings(
        markerKey: String,
        savedEnvironment: [String: String],
        environment: inout [String: String]
    ) {
        let localNames = environment[markerKey]?
            .split(separator: ",")
            .map(String.init) ?? []
        environment.removeValue(forKey: markerKey)

        for name in localNames {
            if let savedValue = savedEnvironment[name] {
                environment[name] = savedValue
            } else {
                environment.removeValue(forKey: name)
            }
        }
    }

    private static func executeSourceBuiltin(
        commandName: String,
        args: [String],
        stdin: Data,
        filesystem: any FileSystem,
        currentDirectory: inout String,
        environment: inout [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        jobControl: (any ShellJobControlling)?,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> CommandResult {
        if args == ["--help"] || args == ["-h"] {
            return CommandResult(
                stdout: Data(
                    """
                    OVERVIEW: Execute commands from a file in the current shell

                    USAGE: \(commandName) <file>

                    """.utf8
                ),
                stderr: Data(),
                exitCode: 0
            )
        }

        guard let file = args.first else {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(commandName): filename argument required\n".utf8),
                exitCode: 2
            )
        }

        let path = WorkspacePath(
            normalizing: file,
            relativeTo: WorkspacePath(normalizing: currentDirectory)
        )

        let data: Data
        do {
            data = try await filesystem.readFile(path: path)
        } catch {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(commandName): \(file): \(error)\n".utf8),
                exitCode: 1
            )
        }

        guard let script = String(data: data, encoding: .utf8) else {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(commandName): \(file): invalid UTF-8\n".utf8),
                exitCode: 1
            )
        }

        let parsed: ParsedLine
        do {
            parsed = try ShellParser.parse(script)
        } catch {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(error)\n".utf8),
                exitCode: 2
            )
        }

        let execution = await execute(
            parsedLine: parsed,
            stdin: stdin,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            jobControl: jobControl,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )

        currentDirectory = execution.currentDirectory
        environment = execution.environment
        return execution.result
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
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> WordExpansionOutcome {
        var expanded: [String] = []
        var stderr = Data()

        for word in words {
            let result = await expandWord(
                word,
                filesystem: filesystem,
                currentDirectory: currentDirectory,
                environment: environment,
                history: history,
                commandRegistry: commandRegistry,
                shellFunctions: shellFunctions,
                enableGlobbing: enableGlobbing,
                permissionAuthorizer: permissionAuthorizer,
                executionControl: executionControl,
                secretPolicy: secretPolicy,
                secretResolver: secretResolver,
                secretTracker: secretTracker,
                secretOutputRedactor: secretOutputRedactor
            )
            stderr.append(result.stderr)
            if result.failure != nil || result.error != nil {
                return WordExpansionOutcome(
                    words: expanded,
                    stderr: stderr,
                    error: result.error,
                    failure: result.failure
                )
            }
            expanded.append(contentsOf: result.words)
        }

        return WordExpansionOutcome(words: expanded, stderr: stderr, error: nil, failure: nil)
    }

    private static func firstExpansion(
        word: ShellWord,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        let expanded = await expandWord(
            word,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )
        return TextExpansionOutcome(
            text: expanded.words.first ?? "",
            stderr: expanded.stderr,
            error: expanded.error,
            failure: expanded.failure
        )
    }

    private static func expandWord(
        _ word: ShellWord,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> WordExpansionOutcome {
        var variants = [""]
        var stderr = Data()

        for part in word.parts {
            var partValues: [String] = []
            switch part.quote {
            case .single:
                partValues = [part.text]
            case .double:
                partValues = [expandVariables(in: part.text, environment: environment)]
            case .none:
                for braceValue in BraceExpansion.expand(part.text) {
                    let expandedPart = await expandUnquotedWordPart(
                        braceValue,
                        filesystem: filesystem,
                        currentDirectory: currentDirectory,
                        environment: environment,
                        history: history,
                        commandRegistry: commandRegistry,
                        shellFunctions: shellFunctions,
                        enableGlobbing: enableGlobbing,
                        permissionAuthorizer: permissionAuthorizer,
                        executionControl: executionControl,
                        secretPolicy: secretPolicy,
                        secretResolver: secretResolver,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    stderr.append(expandedPart.stderr)
                    if expandedPart.failure != nil || expandedPart.error != nil {
                        return WordExpansionOutcome(
                            words: [],
                            stderr: stderr,
                            error: expandedPart.error,
                            failure: expandedPart.failure
                        )
                    }
                    partValues.append(expandedPart.text)
                }
            }

            var combinedVariants: [String] = []
            for prefix in variants {
                for value in partValues {
                    combinedVariants.append(prefix + value)
                }
            }
            variants = combinedVariants
        }

        var output: [String] = []
        for variant in variants {
            guard enableGlobbing, word.hasUnquotedWildcard, WorkspacePath.containsGlob(variant) else {
                output.append(variant)
                continue
            }

            do {
                let matches = try await filesystem.glob(
                    pattern: variant,
                    currentDirectory: WorkspacePath(normalizing: currentDirectory)
                )
                output.append(contentsOf: matches.isEmpty ? [variant] : matches.map(\.string))
            } catch {
                output.append(variant)
            }
        }

        return WordExpansionOutcome(words: output, stderr: stderr, error: nil, failure: nil)
    }

    private static func expandUnquotedWordPart(
        _ text: String,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        var output = ""
        var pending = ""
        var stderr = Data()
        var index = text.startIndex

        while index < text.endIndex {
            if let substitution = try? ProcessSubstitutionSyntax.capture(in: text, from: index) {
                output += expandVariables(in: pending, environment: environment)
                pending.removeAll(keepingCapacity: true)

                switch substitution.kind {
                case .input:
                    let materialized = await materializeInputProcessSubstitution(
                        substitution.content,
                        filesystem: filesystem,
                        currentDirectory: currentDirectory,
                        environment: environment,
                        history: history,
                        commandRegistry: commandRegistry,
                        shellFunctions: shellFunctions,
                        enableGlobbing: enableGlobbing,
                        permissionAuthorizer: permissionAuthorizer,
                        executionControl: executionControl,
                        secretPolicy: secretPolicy,
                        secretResolver: secretResolver,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    stderr.append(materialized.stderr)
                    if materialized.failure != nil || materialized.error != nil {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: materialized.error,
                            failure: materialized.failure
                        )
                    }
                    output += materialized.text
                case .output:
                    return TextExpansionOutcome(
                        text: output,
                        stderr: stderr,
                        error: .unsupported("output process substitution >(...) is not supported"),
                        failure: nil
                    )
                }

                index = substitution.endIndex
                continue
            }

            pending.append(text[index])
            index = text.index(after: index)
        }

        output += expandVariables(in: pending, environment: environment)
        return TextExpansionOutcome(text: output, stderr: stderr, error: nil, failure: nil)
    }

    private static func materializeInputProcessSubstitution(
        _ command: String,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        let nested = await expandCommandSubstitutionsInCommandText(
            command,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )
        if nested.failure != nil || nested.error != nil {
            return nested
        }

        let parsed: ParsedLine
        do {
            parsed = try ShellParser.parse(nested.text)
        } catch let shellError as ShellError {
            return TextExpansionOutcome(text: "", stderr: nested.stderr, error: shellError, failure: nil)
        } catch {
            return TextExpansionOutcome(text: "", stderr: nested.stderr, error: .parserError("\(error)"), failure: nil)
        }

        let execution = await execute(
            parsedLine: parsed,
            stdin: Data(),
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            jobControl: nil,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )

        let tempDirectory = WorkspacePath(normalizing: "/tmp")
        let tempPath = WorkspacePath(normalizing: "/tmp/bashswift-ps-\(UUID().uuidString.lowercased())")
        var stderr = nested.stderr
        stderr.append(execution.result.stderr)

        do {
            try await filesystem.createDirectory(path: tempDirectory, recursive: true)
            try await filesystem.writeFile(path: tempPath, data: execution.result.stdout, append: false)
        } catch {
            stderr.append(Data("\(tempPath.string): \(error)\n".utf8))
            return TextExpansionOutcome(
                text: "",
                stderr: stderr,
                error: nil,
                failure: ExecutionFailure(exitCode: 1, message: "process substitution failed")
            )
        }

        return TextExpansionOutcome(text: tempPath.string, stderr: stderr, error: nil, failure: nil)
    }

    private static func applyRedirectionExpansionFailure(
        _ expansion: TextExpansionOutcome,
        to result: inout CommandResult
    ) -> CommandResult? {
        result.stderr.append(expansion.stderr)
        if let failure = expansion.failure {
            return CommandResult(stdout: Data(), stderr: result.stderr, exitCode: failure.exitCode)
        }
        if let error = expansion.error {
            result.stderr.append(Data("\(error)\n".utf8))
            return CommandResult(stdout: Data(), stderr: result.stderr, exitCode: 2)
        }
        return nil
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

            if string[next] == "@" || string[next] == "*" || string[next] == "#" {
                result += environment[String(string[next])] ?? ""
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
                    let evaluated = ArithmeticEvaluator.evaluate(
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

    private struct PendingHereDocumentCapture: Sendable {
        let delimiter: String
        let stripsLeadingTabs: Bool
    }

    private static func expandHereDocumentBody(
        _ hereDocument: HereDocument,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        guard hereDocument.allowsExpansion else {
            return TextExpansionOutcome(
                text: hereDocument.body,
                stderr: Data(),
                error: nil,
                failure: nil
            )
        }

        return await expandUnquotedHereDocumentText(
            hereDocument.body,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )
    }

    private static func expandUnquotedHereDocumentText(
        _ text: String,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        var output = ""
        var stderr = Data()
        var index = text.startIndex

        func readIdentifier(startingAt start: String.Index) -> (String, String.Index) {
            var cursor = start
            var value = ""
            while cursor < text.endIndex {
                let character = text[cursor]
                if character.isLetter || character.isNumber || character == "_" {
                    value.append(character)
                    cursor = text.index(after: cursor)
                } else {
                    break
                }
            }
            return (value, cursor)
        }

        while index < text.endIndex {
            if let failure = await executionControl?.checkpoint() {
                return TextExpansionOutcome(
                    text: output,
                    stderr: Data("\(failure.message)\n".utf8),
                    error: nil,
                    failure: failure
                )
            }

            let character = text[index]

            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    let escaped = text[next]
                    if escaped == "\n" {
                        index = text.index(after: next)
                        continue
                    }
                    if escaped == "$" || escaped == "\\" {
                        output.append(escaped)
                        index = text.index(after: next)
                        continue
                    }
                }

                output.append("\\")
                index = next
                continue
            }

            guard character == "$" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }

            let next = text.index(after: index)
            guard next < text.endIndex else {
                output.append("$")
                break
            }

            if text[next] == "(" {
                let maybeSecondOpen = text.index(after: next)
                if maybeSecondOpen < text.endIndex, text[maybeSecondOpen] == "(",
                   let capture = captureArithmeticExpansion(in: text, secondOpen: maybeSecondOpen) {
                    let evaluated = ArithmeticEvaluator.evaluate(
                        capture.expression,
                        environment: environment
                    ) ?? 0
                    output += String(evaluated)
                    index = capture.endIndex
                    continue
                }

                do {
                    let capture = try captureCommandSubstitution(in: text, from: index)
                    let evaluated = await evaluateCommandSubstitutionInCommandText(
                        capture.content,
                        filesystem: filesystem,
                        currentDirectory: currentDirectory,
                        environment: environment,
                        history: history,
                        commandRegistry: commandRegistry,
                        shellFunctions: shellFunctions,
                        enableGlobbing: enableGlobbing,
                        permissionAuthorizer: permissionAuthorizer,
                        executionControl: executionControl,
                        secretPolicy: secretPolicy,
                        secretResolver: secretResolver,
                        secretTracker: secretTracker,
                        secretOutputRedactor: secretOutputRedactor
                    )
                    output += evaluated.text
                    stderr.append(evaluated.stderr)
                    if let error = evaluated.error {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: error,
                            failure: nil
                        )
                    }
                    if let failure = evaluated.failure {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: nil,
                            failure: failure
                        )
                    }
                    index = capture.endIndex
                    continue
                } catch let shellError as ShellError {
                    return TextExpansionOutcome(
                        text: output,
                        stderr: stderr,
                        error: shellError,
                        failure: nil
                    )
                } catch {
                    return TextExpansionOutcome(
                        text: output,
                        stderr: stderr,
                        error: .parserError("\(error)"),
                        failure: nil
                    )
                }
            }

            if text[next] == "!" {
                output += environment["!"] ?? ""
                index = text.index(after: next)
                continue
            }

            if text[next] == "@" || text[next] == "*" || text[next] == "#" {
                output += environment[String(text[next])] ?? ""
                index = text.index(after: next)
                continue
            }

            if text[next] == "{" {
                guard let close = text[next...].firstIndex(of: "}") else {
                    output.append("$")
                    index = next
                    continue
                }

                let contentStart = text.index(after: next)
                let content = String(text[contentStart..<close])

                if let range = content.range(of: ":-") {
                    let key = String(content[..<range.lowerBound])
                    let fallback = String(content[range.upperBound...])
                    let value = environment[key]
                    if let value, !value.isEmpty {
                        output += value
                    } else {
                        output += fallback
                    }
                } else {
                    output += environment[content] ?? ""
                }

                index = text.index(after: close)
                continue
            }

            let (key, end) = readIdentifier(startingAt: next)
            if key.isEmpty {
                output.append("$")
                index = next
            } else {
                output += environment[key] ?? ""
                index = end
            }
        }

        return TextExpansionOutcome(
            text: output,
            stderr: stderr,
            error: nil,
            failure: nil
        )
    }

    private static func expandCommandSubstitutionsInCommandText(
        _ commandLine: String,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        var output = ""
        var stderr = Data()
        var quote: QuoteKind = .none
        var index = commandLine.startIndex
        var pendingHereDocuments: [PendingHereDocumentCapture] = []

        while index < commandLine.endIndex {
            if let failure = await executionControl?.checkpoint() {
                return TextExpansionOutcome(
                    text: output,
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
               let hereDocument = captureHereDocumentDeclaration(in: commandLine, from: index) {
                output.append(contentsOf: commandLine[index..<hereDocument.endIndex])
                pendingHereDocuments.append(
                    PendingHereDocumentCapture(
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
                        let capture = try captureHereDocumentBodiesVerbatim(
                            in: commandLine,
                            from: index,
                            hereDocuments: pendingHereDocuments
                        )
                        output.append(contentsOf: capture.raw)
                        index = capture.endIndex
                        pendingHereDocuments.removeAll(keepingCapacity: true)
                    } catch let shellError as ShellError {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: shellError,
                            failure: nil
                        )
                    } catch {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: .parserError("\(error)"),
                            failure: nil
                        )
                    }
                }
                continue
            }

            if quote != .single, character == "$" {
                if let arithmetic = captureArithmeticExpansion(in: commandLine, from: index) {
                    output.append(arithmetic.raw)
                    index = arithmetic.endIndex
                    continue
                }

                let next = commandLine.index(after: index)
                if next < commandLine.endIndex, commandLine[next] == "(" {
                    do {
                        let capture = try captureCommandSubstitution(in: commandLine, from: index)
                        let evaluated = await evaluateCommandSubstitutionInCommandText(
                            capture.content,
                            filesystem: filesystem,
                            currentDirectory: currentDirectory,
                            environment: environment,
                            history: history,
                            commandRegistry: commandRegistry,
                            shellFunctions: shellFunctions,
                            enableGlobbing: enableGlobbing,
                            permissionAuthorizer: permissionAuthorizer,
                            executionControl: executionControl,
                            secretPolicy: secretPolicy,
                            secretResolver: secretResolver,
                            secretTracker: secretTracker,
                            secretOutputRedactor: secretOutputRedactor
                        )
                        output.append(evaluated.text)
                        stderr.append(evaluated.stderr)
                        if let error = evaluated.error {
                            return TextExpansionOutcome(
                                text: output,
                                stderr: stderr,
                                error: error,
                                failure: nil
                            )
                        }
                        if let failure = evaluated.failure {
                            return TextExpansionOutcome(
                                text: output,
                                stderr: stderr,
                                error: nil,
                                failure: failure
                            )
                        }
                        index = capture.endIndex
                        continue
                    } catch let shellError as ShellError {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: shellError,
                            failure: nil
                        )
                    } catch {
                        return TextExpansionOutcome(
                            text: output,
                            stderr: stderr,
                            error: .parserError("\(error)"),
                            failure: nil
                        )
                    }
                }
            }

            output.append(character)
            index = commandLine.index(after: index)
        }

        return TextExpansionOutcome(
            text: output,
            stderr: stderr,
            error: nil,
            failure: nil
        )
    }

    private static func evaluateCommandSubstitutionInCommandText(
        _ command: String,
        filesystem: any FileSystem,
        currentDirectory: String,
        environment: [String: String],
        history: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        shellFunctions: [String: String],
        enableGlobbing: Bool,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        secretTracker: SecretExposureTracker?,
        secretOutputRedactor: any SecretOutputRedacting
    ) async -> TextExpansionOutcome {
        if let failure = await executionControl?.pushCommandSubstitution() {
            return TextExpansionOutcome(
                text: "",
                stderr: Data("\(failure.message)\n".utf8),
                error: nil,
                failure: failure
            )
        }

        let nested = await expandCommandSubstitutionsInCommandText(
            command,
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )
        await executionControl?.popCommandSubstitution()
        if let failure = nested.failure {
            return TextExpansionOutcome(
                text: "",
                stderr: nested.stderr,
                error: nil,
                failure: failure
            )
        }
        if nested.error != nil {
            return nested
        }

        let parsed: ParsedLine
        do {
            parsed = try ShellParser.parse(nested.text)
        } catch let shellError as ShellError {
            return TextExpansionOutcome(
                text: "",
                stderr: nested.stderr,
                error: shellError,
                failure: nil
            )
        } catch {
            return TextExpansionOutcome(
                text: "",
                stderr: nested.stderr,
                error: .parserError("\(error)"),
                failure: nil
            )
        }

        let execution = await execute(
            parsedLine: parsed,
            stdin: Data(),
            filesystem: filesystem,
            currentDirectory: currentDirectory,
            environment: environment,
            history: history,
            commandRegistry: commandRegistry,
            shellFunctions: shellFunctions,
            enableGlobbing: enableGlobbing,
            jobControl: nil,
            permissionAuthorizer: permissionAuthorizer,
            executionControl: executionControl,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            secretTracker: secretTracker,
            secretOutputRedactor: secretOutputRedactor
        )

        var stderr = nested.stderr
        stderr.append(execution.result.stderr)

        return TextExpansionOutcome(
            text: trimmingTrailingNewlines(from: execution.result.stdoutString),
            stderr: stderr,
            error: nil,
            failure: nil
        )
    }

    private static func captureArithmeticExpansion(
        in string: String,
        from dollarIndex: String.Index
    ) -> (raw: String, endIndex: String.Index)? {
        let open = string.index(after: dollarIndex)
        guard open < string.endIndex, string[open] == "(" else {
            return nil
        }

        let secondOpen = string.index(after: open)
        guard secondOpen < string.endIndex, string[secondOpen] == "(" else {
            return nil
        }

        var depth = 1
        var cursor = string.index(after: secondOpen)

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
                        let end = string.index(after: next)
                        return (raw: String(string[dollarIndex..<end]), endIndex: end)
                    }
                    cursor = string.index(after: next)
                    continue
                }
            }
            cursor = string.index(after: cursor)
        }

        return nil
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
                if character == "$" {
                    let next = commandLine.index(after: index)
                    if next < commandLine.endIndex, commandLine[next] == "(" {
                        let secondOpen = commandLine.index(after: next)
                        if secondOpen < commandLine.endIndex, commandLine[secondOpen] == "(" {
                            index = commandLine.index(after: index)
                            continue
                        }
                        depth += 1
                        index = commandLine.index(after: next)
                        continue
                    }
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

        return (
            delimiter: delimiter,
            stripsLeadingTabs: stripsLeadingTabs,
            endIndex: index
        )
    }

    private static func captureHereDocumentBodiesVerbatim(
        in commandLine: String,
        from startIndex: String.Index,
        hereDocuments: [PendingHereDocumentCapture]
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
                    ? stripLeadingTabs(from: line)
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

    private static func trimmingTrailingNewlines(from string: String) -> String {
        var output = string
        while output.last == "\n" || output.last == "\r" {
            output.removeLast()
        }
        return output
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

}
