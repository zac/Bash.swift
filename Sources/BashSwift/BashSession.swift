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
        self.options = options

        let filesystem = options.filesystem
        try filesystem.configure(rootDirectory: rootDirectory)
        filesystemStore = filesystem

        commandRegistry = [:]
        historyStore = []

        switch options.layout {
        case .unixLike:
            currentDirectoryStore = "/home/user"
        case .rootOnly:
            currentDirectoryStore = "/"
        }

        var defaults: [String: String] = [
            "HOME": "/home/user",
            "PWD": currentDirectoryStore,
            "PATH": "/bin:/usr/bin",
            "USER": "user",
            "TMPDIR": "/tmp",
        ]

        defaults.merge(options.initialEnvironment) { _, rhs in rhs }
        environmentStore = defaults

        try await setupLayout()
        await registerDefaultCommands()
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
            try await filesystemStore.createDirectory(path: "/", recursive: true)
        case .unixLike:
            for path in ["/home/user", "/bin", "/usr/bin", "/tmp"] {
                try await filesystemStore.createDirectory(path: path, recursive: true)
            }
        }
    }

    private func createCommandStub(named commandName: String) async {
        let content = "#!/bin/sh\n# BashSwift built-in: \(commandName)\n"
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

}
