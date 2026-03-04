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

        guard let implementation = resolveCommand(named: commandName, registry: commandRegistry) else {
            let message = "\(commandName): command not found\n"
            return CommandResult(stdout: Data(), stderr: Data(message.utf8), exitCode: 127)
        }

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

        var result = CommandResult(stdout: context.stdout, stderr: context.stderr, exitCode: exitCode)

        currentDirectory = context.currentDirectory
        environment = context.environment

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
