import Foundation
import BashCore

public final actor BashSession {
    let filesystemStore: any FileSystem
    public nonisolated let workspace: Workspace
    private let options: SessionOptions
    let jobManager: ShellJobManager
    private let permissionAuthorizer: ShellPermissionAuthorizer
    var executionControlStore: ExecutionControl?
    private var secretPolicyStore: SecretHandlingPolicy
    private var secretResolverStore: (any SecretReferenceResolving)?
    private var secretOutputRedactorStore: any SecretOutputRedacting

    var currentDirectoryStore: String
    var environmentStore: [String: String]
    private var historyStore: [String]
    private var commandRegistry: [String: AnyBuiltinCommand]
    var shellFunctionStore: [String: String]

    public var currentDirectory: String {
        currentDirectoryStore
    }

    public var environment: [String: String] {
        environmentStore
    }

    public init(rootDirectory: URL, options: SessionOptions = .init()) async throws {
        let filesystem = options.filesystem
        try await filesystem.configure(rootDirectory: rootDirectory)
        let workspace = options.workspace ?? Workspace(filesystem: filesystem)
        try await self.init(options: options, configuredFilesystem: filesystem, workspace: workspace)
    }

    public init(options: SessionOptions = .init()) async throws {
        let filesystem = options.filesystem
        let workspace = options.workspace ?? Workspace(filesystem: filesystem)
        try await self.init(options: options, configuredFilesystem: filesystem, workspace: workspace)
    }

    public func run(_ commandLine: String, stdin: Data = Data()) async -> CommandResult {
        await run(commandLine, options: RunOptions(stdin: stdin))
    }

    public func run(_ commandLine: String, options: RunOptions) async -> CommandResult {
        let usesTemporaryState = options.currentDirectory != nil
            || !options.environment.isEmpty
            || options.replaceEnvironment
        let executionControl = ExecutionControl(
            limits: options.executionLimits ?? self.options.executionLimits,
            cancellationCheck: options.cancellationCheck
        )
        guard usesTemporaryState else {
            return await runWithExecutionControl(
                commandLine,
                stdin: options.stdin,
                executionControl: executionControl
            )
        }

        let savedCurrentDirectory = currentDirectoryStore
        let savedEnvironment = environmentStore
        let savedFunctions = shellFunctionStore

        if let overrideDirectory = options.currentDirectory {
            do {
                try validateWorkspacePath(overrideDirectory)
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
            currentDirectoryStore = normalizeWorkspacePath(
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

        let result = await runWithExecutionControl(
            commandLine,
            stdin: options.stdin,
            executionControl: executionControl
        )

        currentDirectoryStore = savedCurrentDirectory
        environmentStore = savedEnvironment
        shellFunctionStore = savedFunctions
        return result
    }

    private func runWithExecutionControl(
        _ commandLine: String,
        stdin: Data,
        executionControl: ExecutionControl
    ) async -> CommandResult {
        guard let maxWallClockDuration = executionControl.limits.maxWallClockDuration else {
            return await runPersistingState(
                commandLine,
                stdin: stdin,
                executionControl: executionControl
            )
        }

        enum Outcome {
            case completed(CommandResult)
            case timedOut
        }

        let task = Task {
            await self.runPersistingState(
                commandLine,
                stdin: stdin,
                executionControl: executionControl
            )
        }

        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                .completed(await task.value)
            }

            group.addTask {
                while !Task.isCancelled {
                    let elapsed = await executionControl.currentEffectiveElapsedTime()
                    if elapsed >= maxWallClockDuration {
                        return .timedOut
                    }

                    let remaining = max(0.001, min(maxWallClockDuration - elapsed, 0.01))
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
        case let .completed(result):
            return result
        case .timedOut:
            await executionControl.markTimedOut()
            task.cancel()
            return CommandResult(
                stdout: Data(),
                stderr: Data("execution timed out\n".utf8),
                exitCode: 124
            )
        }
    }

    private func runPersistingState(
        _ commandLine: String,
        stdin: Data,
        executionControl: ExecutionControl
    ) async -> CommandResult {
        let savedExecutionControl = executionControlStore
        executionControlStore = executionControl
        defer { executionControlStore = savedExecutionControl }

        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }

        if let failure = await executionControl.checkpoint() {
            return CommandResult(
                stdout: Data(),
                stderr: Data("\(failure.message)\n".utf8),
                exitCode: failure.exitCode
            )
        }

        historyStore.append(trimmed)
        if historyStore.count > options.maxHistory {
            historyStore.removeFirst(historyStore.count - options.maxHistory)
        }

        var substitution = await expandCommandSubstitutions(in: commandLine)
        if let failure = substitution.failure {
            return CommandResult(
                stdout: Data(),
                stderr: substitution.stderr,
                exitCode: failure.exitCode
            )
        }
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

    public func register(_ command: AnyBuiltinCommand) async {
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

    public func configureSecrets(
        policy: SecretHandlingPolicy,
        resolver: (any SecretReferenceResolving)?,
        redactor: any SecretOutputRedacting = DefaultSecretOutputRedactor()
    ) {
        secretPolicyStore = policy
        secretResolverStore = resolver
        secretOutputRedactorStore = redactor
    }

    public func setSecretHandlingPolicy(_ policy: SecretHandlingPolicy) {
        secretPolicyStore = policy
    }

    public func setSecretResolver(_ resolver: (any SecretReferenceResolving)?) {
        secretResolverStore = resolver
    }

    public func setSecretOutputRedactor(_ redactor: any SecretOutputRedacting) {
        secretOutputRedactorStore = redactor
    }

    private func setupLayout() async throws {
        switch options.layout {
        case .rootOnly:
            // Backends are configured with a root by construction. Creating "/"
            // can resolve to the parent of the jailed root for some adapters.
            break
        case .unixLike:
            for path in ["/home/user", "/bin", "/usr/bin", "/tmp"] {
                try await filesystemStore.createDirectory(path: WorkspacePath(normalizing: path), recursive: true)
            }
        }
    }

    private func createCommandStub(named commandName: String) async {
        let content = "#!/bin/sh\n# Bash built-in: \(commandName)\n"
        let data = Data(content.utf8)

        for directory in ["/bin", "/usr/bin"] {
            let path = WorkspacePath(normalizing: "\(directory)/\(commandName)")
            if await filesystemStore.exists(path: path) {
                continue
            }

            do {
                try await filesystemStore.writeFile(path: path, data: data, append: false)
                try await filesystemStore.setPermissions(path: path, permissions: POSIXPermissions(0o755))
            } catch {
                // Best effort for command lookup stubs.
            }
        }
    }

    private init(options: SessionOptions, configuredFilesystem: any FileSystem, workspace: Workspace) async throws {
        self.options = options
        filesystemStore = configuredFilesystem
        self.workspace = workspace
        jobManager = ShellJobManager()
        permissionAuthorizer = ShellPermissionAuthorizer(
            networkPolicy: options.networkPolicy,
            handler: options.permissionHandler
        )
        executionControlStore = nil
        secretPolicyStore = options.secretPolicy
        secretResolverStore = options.secretResolver
        secretOutputRedactorStore = options.secretOutputRedactor

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
        await registerCompiledCommands()
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

    func executeParsedLine(
        parsedLine: ParsedLine,
        stdin: Data,
        currentDirectory: String,
        environment: [String: String],
        shellFunctions: [String: String],
        jobControl: (any ShellJobControlling)?
    ) async -> ShellExecutionResult {
        let secretPolicy = secretPolicyStore
        let secretResolver = secretResolverStore
        let secretOutputRedactor = secretOutputRedactorStore
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
            executionControl: executionControlStore,
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

    func executeStandardCommandLine(
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
}
