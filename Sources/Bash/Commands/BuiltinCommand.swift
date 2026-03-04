import ArgumentParser
import Foundation

public struct CommandContext: Sendable {
    public let commandName: String
    public let arguments: [String]
    public let filesystem: any ShellFilesystem
    public let enableGlobbing: Bool
    public let secretPolicy: SecretHandlingPolicy
    public let secretResolver: (any SecretReferenceResolving)?
    public let availableCommands: [String]
    public let commandRegistry: [String: AnyBuiltinCommand]
    public let history: [String]

    public var currentDirectory: String
    public var environment: [String: String]
    public var stdin: Data
    public var stdout: Data
    public var stderr: Data
    let secretTracker: SecretExposureTracker?
    let jobControl: (any ShellJobControlling)?

    public init(
        commandName: String,
        arguments: [String],
        filesystem: any ShellFilesystem,
        enableGlobbing: Bool,
        secretPolicy: SecretHandlingPolicy = .off,
        secretResolver: (any SecretReferenceResolving)? = nil,
        availableCommands: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        history: [String],
        currentDirectory: String,
        environment: [String: String],
        stdin: Data,
        stdout: Data = Data(),
        stderr: Data = Data()
    ) {
        self.init(
            commandName: commandName,
            arguments: arguments,
            filesystem: filesystem,
            enableGlobbing: enableGlobbing,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            availableCommands: availableCommands,
            commandRegistry: commandRegistry,
            history: history,
            currentDirectory: currentDirectory,
            environment: environment,
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            secretTracker: nil,
            jobControl: nil
        )
    }

    init(
        commandName: String,
        arguments: [String],
        filesystem: any ShellFilesystem,
        enableGlobbing: Bool,
        secretPolicy: SecretHandlingPolicy,
        secretResolver: (any SecretReferenceResolving)?,
        availableCommands: [String],
        commandRegistry: [String: AnyBuiltinCommand],
        history: [String],
        currentDirectory: String,
        environment: [String: String],
        stdin: Data,
        stdout: Data = Data(),
        stderr: Data = Data(),
        secretTracker: SecretExposureTracker?,
        jobControl: (any ShellJobControlling)? = nil
    ) {
        self.commandName = commandName
        self.arguments = arguments
        self.filesystem = filesystem
        self.enableGlobbing = enableGlobbing
        self.secretPolicy = secretPolicy
        self.secretResolver = secretResolver
        self.availableCommands = availableCommands
        self.commandRegistry = commandRegistry
        self.history = history
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.secretTracker = secretTracker
        self.jobControl = jobControl
    }

    public mutating func writeStdout(_ string: String) {
        stdout.append(Data(string.utf8))
    }

    public mutating func writeStderr(_ string: String) {
        stderr.append(Data(string.utf8))
    }

    public func resolvePath(_ path: String) -> String {
        PathUtils.normalize(path: path, currentDirectory: currentDirectory)
    }

    public func environmentValue(_ key: String) -> String {
        environment[key] ?? ""
    }

    public mutating func registerSensitiveValue(
        _ value: Data,
        replacement: Data? = nil
    ) async {
        guard let tracker = secretTracker else {
            return
        }

        await tracker.record(secret: value, replacement: replacement)
    }

    public mutating func registerSensitiveValue(
        _ value: String,
        replacement: String? = nil
    ) async {
        await registerSensitiveValue(
            Data(value.utf8),
            replacement: replacement.map { Data($0.utf8) }
        )
    }

    public mutating func resolveSecretReferenceIfEnabled(
        _ reference: String
    ) async throws -> Data? {
        switch secretPolicy {
        case .off:
            return nil
        case .resolveAndRedact, .strict:
            guard let resolver = secretResolver else {
                throw ShellError.unsupported("secret resolver is not configured")
            }

            let value = try await resolver.resolveSecretReference(reference)
            await registerSensitiveValue(
                value,
                replacement: Data(reference.utf8)
            )
            return value
        }
    }

    public mutating func resolveSecretReference(
        _ reference: String
    ) async throws -> Data {
        if let resolved = try await resolveSecretReferenceIfEnabled(reference) {
            return resolved
        }

        guard let resolver = secretResolver else {
            throw ShellError.unsupported("secret resolver is not configured")
        }

        let value = try await resolver.resolveSecretReference(reference)
        await registerSensitiveValue(
            value,
            replacement: Data(reference.utf8)
        )
        return value
    }

    public mutating func runSubcommand(
        _ argv: [String],
        stdin: Data? = nil
    ) async -> CommandResult {
        let outcome = await runSubcommandIsolated(argv, stdin: stdin)
        currentDirectory = outcome.currentDirectory
        environment = outcome.environment
        return outcome.result
    }

    public func runSubcommandIsolated(
        _ argv: [String],
        stdin: Data? = nil
    ) async -> (result: CommandResult, currentDirectory: String, environment: [String: String]) {
        guard let commandName = argv.first else {
            return (CommandResult(stdout: Data(), stderr: Data(), exitCode: 0), currentDirectory, environment)
        }

        guard let implementation = resolveCommand(named: commandName) else {
            let message = "\(commandName): command not found\n"
            return (
                CommandResult(stdout: Data(), stderr: Data(message.utf8), exitCode: 127),
                currentDirectory,
                environment
            )
        }

        let commandArgs = Array(argv.dropFirst())
        var childContext = CommandContext(
            commandName: commandName,
            arguments: commandArgs,
            filesystem: filesystem,
            enableGlobbing: enableGlobbing,
            secretPolicy: secretPolicy,
            secretResolver: secretResolver,
            availableCommands: availableCommands,
            commandRegistry: commandRegistry,
            history: history,
            currentDirectory: currentDirectory,
            environment: environment,
            stdin: stdin ?? self.stdin,
            secretTracker: secretTracker,
            jobControl: jobControl
        )

        let exitCode = await implementation.runCommand(&childContext, commandArgs)
        return (
            CommandResult(stdout: childContext.stdout, stderr: childContext.stderr, exitCode: exitCode),
            childContext.currentDirectory,
            childContext.environment
        )
    }

    private func resolveCommand(named commandName: String) -> AnyBuiltinCommand? {
        if commandName.hasPrefix("/") {
            return commandRegistry[PathUtils.basename(commandName)]
        }

        if let direct = commandRegistry[commandName] {
            return direct
        }

        if commandName.contains("/") {
            return commandRegistry[PathUtils.basename(commandName)]
        }

        return nil
    }

    var supportsJobControl: Bool {
        jobControl != nil
    }

    func listJobs() async -> [ShellJobSnapshot] {
        guard let jobControl else {
            return []
        }
        return await jobControl.listJobs()
    }

    func hasJobs() async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.hasJobs()
    }

    func hasJob(id: Int) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.hasJob(id: id)
    }

    func hasProcess(pid: Int) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.hasProcess(pid: pid)
    }

    func snapshotForProcess(pid: Int) async -> ShellJobSnapshot? {
        guard let jobControl else {
            return nil
        }
        return await jobControl.processSnapshot(pid: pid)
    }

    func foregroundJob(id: Int?) async -> ShellJobCompletion? {
        guard let jobControl else {
            return nil
        }
        return await jobControl.foreground(jobID: id)
    }

    func waitForJob(id: Int) async -> ShellJobCompletion? {
        guard let jobControl else {
            return nil
        }
        return await jobControl.waitForJob(id: id)
    }

    func waitForAllJobs() async -> [ShellJobCompletion] {
        guard let jobControl else {
            return []
        }
        return await jobControl.waitForAllJobs()
    }

    func terminateJob(id: Int, signal: Int32) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.terminate(reference: .jobID(id), signal: signal)
    }

    func terminateProcess(pid: Int, signal: Int32) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.terminate(reference: .pid(pid), signal: signal)
    }
}

public protocol BuiltinCommand {
    associatedtype Options: ParsableArguments

    static var name: String { get }
    static var aliases: [String] { get }
    static var overview: String { get }

    static func run(context: inout CommandContext, options: Options) async -> Int32
    static func _toAnyBuiltinCommand() -> AnyBuiltinCommand
}

public extension BuiltinCommand {
    static var aliases: [String] { [] }

    static func _toAnyBuiltinCommand() -> AnyBuiltinCommand {
        AnyBuiltinCommand(Self.self)
    }
}

public struct AnyBuiltinCommand: @unchecked Sendable {
    public let name: String
    public let aliases: [String]
    public let overview: String
    public let runCommand: (inout CommandContext, [String]) async -> Int32

    public init<C: BuiltinCommand>(_ command: C.Type) {
        name = command.name
        aliases = command.aliases
        overview = command.overview
        runCommand = { context, args in
            do {
                let options = try C.Options.parse(args)
                return await C.run(context: &context, options: options)
            } catch {
                let message = C.Options.fullMessage(for: error)
                if !message.isEmpty {
                    let output = message.hasSuffix("\n") ? message : message + "\n"
                    let exitCode = C.Options.exitCode(for: error).rawValue
                    if exitCode == 0 {
                        context.writeStdout(output)
                    } else {
                        context.writeStderr(output)
                    }
                }
                return C.Options.exitCode(for: error).rawValue
            }
        }
    }

    public init(
        name: String,
        aliases: [String],
        overview: String,
        runCommand: @escaping (inout CommandContext, [String]) async -> Int32
    ) {
        self.name = name
        self.aliases = aliases
        self.overview = overview
        self.runCommand = runCommand
    }
}
