import ArgumentParser
import Foundation

private actor EffectiveWallClock {
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var pausedDuration: TimeInterval = 0
    private var pauseDepth = 0
    private var pauseStartedAt: TimeInterval?

    func beginPause() {
        if pauseDepth == 0 {
            pauseStartedAt = ProcessInfo.processInfo.systemUptime
        }
        pauseDepth += 1
    }

    func endPause() {
        guard pauseDepth > 0 else {
            return
        }

        pauseDepth -= 1
        guard pauseDepth == 0, let pauseStartedAt else {
            return
        }

        pausedDuration += max(0, ProcessInfo.processInfo.systemUptime - pauseStartedAt)
        self.pauseStartedAt = nil
    }

    func elapsed() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        var effectivePausedDuration = pausedDuration
        if let pauseStartedAt {
            effectivePausedDuration += max(0, now - pauseStartedAt)
        }
        return max(0, now - startedAt - effectivePausedDuration)
    }
}

private actor PermissionPauseAuthorizer: ShellPermissionAuthorizing {
    private let base: any ShellPermissionAuthorizing
    private let clock: EffectiveWallClock

    init(base: any ShellPermissionAuthorizing, clock: EffectiveWallClock) {
        self.base = base
        self.clock = clock
    }

    func authorize(_ request: ShellPermissionRequest) async -> ShellPermissionDecision {
        await clock.beginPause()
        let decision = await base.authorize(request)
        await clock.endPause()
        return decision
    }
}

public struct CommandContext: Sendable {
    public let commandName: String
    public let arguments: [String]
    public let filesystem: any FileSystem
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
    package let secretTracker: SecretExposureTracker?
    package let jobControl: (any ShellJobControlling)?
    package let permissionAuthorizer: any ShellPermissionAuthorizing
    package let executionControl: ExecutionControl?

    public init(
        commandName: String,
        arguments: [String],
        filesystem: any FileSystem,
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
            jobControl: nil,
            permissionAuthorizer: ShellPermissionAuthorizer(),
            executionControl: nil
        )
    }

    package init(
        commandName: String,
        arguments: [String],
        filesystem: any FileSystem,
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
        jobControl: (any ShellJobControlling)? = nil,
        permissionAuthorizer: any ShellPermissionAuthorizing = ShellPermissionAuthorizer(),
        executionControl: ExecutionControl? = nil
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
        self.permissionAuthorizer = permissionAuthorizer
        self.executionControl = executionControl
    }

    public mutating func writeStdout(_ string: String) {
        stdout.append(Data(string.utf8))
    }

    public mutating func writeStderr(_ string: String) {
        stderr.append(Data(string.utf8))
    }

    public var currentDirectoryPath: WorkspacePath {
        WorkspacePath(normalizing: currentDirectory)
    }

    public func resolvePath(_ path: String) -> WorkspacePath {
        WorkspacePath(normalizing: path, relativeTo: currentDirectoryPath)
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

    public func requestPermission(
        _ request: ShellPermissionRequest
    ) async -> ShellPermissionDecision {
        await authorizePermissionRequest(
            request,
            using: permissionAuthorizer,
            pausing: executionControl
        )
    }

    public func requestNetworkPermission(
        url: String,
        method: String
    ) async -> ShellPermissionDecision {
        await requestPermission(
            ShellPermissionRequest(
                command: commandName,
                kind: .network(ShellNetworkPermissionRequest(url: url, method: method))
            )
        )
    }

    public var permissionDelegate: any ShellPermissionAuthorizing {
        permissionAuthorizer
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
        await runSubcommandIsolated(
            argv,
            stdin: stdin,
            executionControlOverride: nil
        )
    }

    package func runSubcommandIsolated(
        _ argv: [String],
        stdin: Data? = nil,
        executionControlOverride: ExecutionControl?,
        permissionAuthorizerOverride: (any ShellPermissionAuthorizing)? = nil
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
        let effectiveExecutionControl = executionControlOverride ?? executionControl
        let effectivePermissionAuthorizer = permissionAuthorizerOverride ?? permissionAuthorizer
        let childFilesystem = ShellPermissionedFileSystem(
            base: ShellPermissionedFileSystem.unwrap(filesystem),
            commandName: commandName,
            permissionAuthorizer: effectivePermissionAuthorizer,
            executionControl: effectiveExecutionControl
        )
        if let failure = await effectiveExecutionControl?.recordCommandExecution(commandName: commandName) {
            return (
                CommandResult(
                    stdout: Data(),
                    stderr: Data("\(failure.message)\n".utf8),
                    exitCode: failure.exitCode
                ),
                currentDirectory,
                environment
            )
        }

        var childContext = CommandContext(
            commandName: commandName,
            arguments: commandArgs,
            filesystem: childFilesystem,
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
            jobControl: jobControl,
            permissionAuthorizer: effectivePermissionAuthorizer,
            executionControl: effectiveExecutionControl
        )

        let exitCode = await implementation.runCommand(&childContext, commandArgs)
        return (
            CommandResult(stdout: childContext.stdout, stderr: childContext.stderr, exitCode: exitCode),
            childContext.currentDirectory,
            childContext.environment
        )
    }

    public func runSubcommandIsolated(
        _ argv: [String],
        stdin: Data? = nil,
        wallClockTimeout: TimeInterval
    ) async -> (result: CommandResult, currentDirectory: String, environment: [String: String]) {
        let clock = EffectiveWallClock()
        let wrappedPermissionAuthorizer = PermissionPauseAuthorizer(
            base: permissionAuthorizer,
            clock: clock
        )

        enum Outcome: Sendable {
            case completed(CommandResult, String, [String: String])
            case timedOut
        }

        let task = Task {
            await runSubcommandIsolated(
                argv,
                stdin: stdin,
                executionControlOverride: executionControl,
                permissionAuthorizerOverride: wrappedPermissionAuthorizer
            )
        }

        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let sub = await task.value
                return .completed(sub.result, sub.currentDirectory, sub.environment)
            }

            group.addTask {
                while !Task.isCancelled {
                    let elapsed = await clock.elapsed()
                    if elapsed >= wallClockTimeout {
                        return .timedOut
                    }

                    let remaining = max(0.001, min(wallClockTimeout - elapsed, 0.01))
                    let sleepNanos = UInt64(remaining * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: sleepNanos)
                }

                return .timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        switch outcome {
        case let .completed(result, currentDirectory, environment):
            return (result, currentDirectory, environment)
        case .timedOut:
            task.cancel()
            return (
                CommandResult(
                    stdout: Data(),
                    stderr: Data("timeout: command timed out\n".utf8),
                    exitCode: 124
                ),
                currentDirectory,
                environment
            )
        }
    }

    private func resolveCommand(named commandName: String) -> AnyBuiltinCommand? {
        if commandName.hasPrefix("/") {
            return commandRegistry[WorkspacePath.basename(commandName)]
        }

        if let direct = commandRegistry[commandName] {
            return direct
        }

        if commandName.contains("/") {
            return commandRegistry[WorkspacePath.basename(commandName)]
        }

        return nil
    }

    package var supportsJobControl: Bool {
        jobControl != nil
    }

    package func listJobs() async -> [ShellJobSnapshot] {
        guard let jobControl else {
            return []
        }
        return await jobControl.listJobs()
    }

    package func hasJobs() async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.hasJobs()
    }

    package func hasJob(id: Int) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.hasJob(id: id)
    }

    package func hasProcess(pid: Int) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.hasProcess(pid: pid)
    }

    package func snapshotForProcess(pid: Int) async -> ShellJobSnapshot? {
        guard let jobControl else {
            return nil
        }
        return await jobControl.processSnapshot(pid: pid)
    }

    package func foregroundJob(id: Int?) async -> ShellJobCompletion? {
        guard let jobControl else {
            return nil
        }
        return await jobControl.foreground(jobID: id)
    }

    package func waitForJob(id: Int) async -> ShellJobCompletion? {
        guard let jobControl else {
            return nil
        }
        return await jobControl.waitForJob(id: id)
    }

    package func waitForAllJobs() async -> [ShellJobCompletion] {
        guard let jobControl else {
            return []
        }
        return await jobControl.waitForAllJobs()
    }

    package func terminateJob(id: Int, signal: Int32) async -> Bool {
        guard let jobControl else {
            return false
        }
        return await jobControl.terminate(reference: .jobID(id), signal: signal)
    }

    package func terminateProcess(pid: Int, signal: Int32) async -> Bool {
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
