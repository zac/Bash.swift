import Foundation

public struct CommandResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

public enum SessionLayout: Sendable {
    case unixLike
    case rootOnly
}

public struct SessionOptions: Sendable {
    public var filesystem: any ShellFilesystem
    public var layout: SessionLayout
    public var initialEnvironment: [String: String]
    public var enableGlobbing: Bool
    public var maxHistory: Int

    public init(
        filesystem: any ShellFilesystem = ReadWriteFilesystem(),
        layout: SessionLayout = .unixLike,
        initialEnvironment: [String: String] = [:],
        enableGlobbing: Bool = true,
        maxHistory: Int = 1_000
    ) {
        self.filesystem = filesystem
        self.layout = layout
        self.initialEnvironment = initialEnvironment
        self.enableGlobbing = enableGlobbing
        self.maxHistory = maxHistory
    }
}

public enum ShellError: Error, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case parserError(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            return "invalid path: \(path)"
        case let .parserError(message):
            return message
        case let .unsupported(message):
            return message
        }
    }
}

public struct FileInfo: Sendable {
    public var path: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: UInt64
    public var permissions: Int
    public var modificationDate: Date?

    public init(
        path: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }
}

public struct DirectoryEntry: Sendable {
    public var name: String
    public var info: FileInfo

    public init(name: String, info: FileInfo) {
        self.name = name
        self.info = info
    }
}
