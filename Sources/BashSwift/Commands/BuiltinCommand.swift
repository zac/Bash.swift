import ArgumentParser
import Foundation

public struct CommandContext {
    public let commandName: String
    public let arguments: [String]
    public let filesystem: any ShellFilesystem
    public let enableGlobbing: Bool
    public let availableCommands: [String]
    public let history: [String]

    public var currentDirectory: String
    public var environment: [String: String]
    public var stdin: Data
    public var stdout: Data
    public var stderr: Data

    public init(
        commandName: String,
        arguments: [String],
        filesystem: any ShellFilesystem,
        enableGlobbing: Bool,
        availableCommands: [String],
        history: [String],
        currentDirectory: String,
        environment: [String: String],
        stdin: Data,
        stdout: Data = Data(),
        stderr: Data = Data()
    ) {
        self.commandName = commandName
        self.arguments = arguments
        self.filesystem = filesystem
        self.enableGlobbing = enableGlobbing
        self.availableCommands = availableCommands
        self.history = history
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
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
}
