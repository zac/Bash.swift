import Foundation

public final actor BashSession {
    let filesystemStore: any ShellFilesystem
    private let options: SessionOptions
    let jobManager: ShellJobManager
    private let permissionAuthorizer: PermissionAuthorizer

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
        permissionAuthorizer = PermissionAuthorizer(
            networkPolicy: options.networkPolicy,
            handler: options.permissionHandler
        )

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

    func executeParsedLine(
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
