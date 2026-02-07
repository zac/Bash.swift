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
        enableGlobbing: Bool
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

            let segmentResult = await executePipeline(
                commands: segment.pipeline,
                initialInput: stdin,
                filesystem: filesystem,
                currentDirectory: &currentDirectory,
                environment: &environment,
                history: history,
                commandRegistry: commandRegistry,
                enableGlobbing: enableGlobbing
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
        enableGlobbing: Bool
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
                enableGlobbing: enableGlobbing
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
        enableGlobbing: Bool
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
            availableCommands: commandRegistry.keys.sorted(),
            history: history,
            currentDirectory: currentDirectory,
            environment: environment,
            stdin: input
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
                    try await filesystem.writeFile(path: path, data: result.stdout, append: redirection.type == .stdoutAppend)
                    result.stdout.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            case .stderrTruncate:
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
                    try await filesystem.writeFile(path: path, data: result.stderr, append: false)
                    result.stderr.removeAll(keepingCapacity: true)
                } catch {
                    result.stderr.append(Data("\(target): \(error)\n".utf8))
                    result.exitCode = 1
                }
            case .stderrToStdout:
                result.stdout.append(result.stderr)
                result.stderr.removeAll(keepingCapacity: true)
            case .stdin:
                continue
            }
        }

        return result
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
}
