import Foundation

public final actor BashSession {
    private let filesystemStore: any ShellFilesystem
    private let options: SessionOptions

    private var currentDirectoryStore: String
    private var environmentStore: [String: String]
    private var historyStore: [String]
    private var commandRegistry: [String: AnyBuiltinCommand]

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

        do {
            let parsed = try ShellParser.parse(commandLine)
            let filesystem = filesystemStore
            let startDirectory = currentDirectoryStore
            let startEnvironment = environmentStore
            let history = historyStore
            let registry = commandRegistry
            let enableGlobbing = options.enableGlobbing

            let execution = await ShellExecutor.execute(
                parsedLine: parsed,
                stdin: stdin,
                filesystem: filesystem,
                currentDirectory: startDirectory,
                environment: startEnvironment,
                history: history,
                commandRegistry: registry,
                enableGlobbing: enableGlobbing
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

        commandRegistry = [:]
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

}
