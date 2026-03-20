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

public struct RunOptions: Sendable {
    public var stdin: Data
    public var environment: [String: String]
    public var replaceEnvironment: Bool
    public var currentDirectory: String?
    public var executionLimits: ExecutionLimits?
    public var cancellationCheck: (@Sendable () -> Bool)?

    public init(
        stdin: Data = Data(),
        environment: [String: String] = [:],
        replaceEnvironment: Bool = false,
        currentDirectory: String? = nil,
        executionLimits: ExecutionLimits? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.stdin = stdin
        self.environment = environment
        self.replaceEnvironment = replaceEnvironment
        self.currentDirectory = currentDirectory
        self.executionLimits = executionLimits
        self.cancellationCheck = cancellationCheck
    }
}

public struct ExecutionLimits: Sendable {
    public static let `default` = ExecutionLimits()

    public var maxCommandCount: Int
    public var maxFunctionDepth: Int
    public var maxLoopIterations: Int
    public var maxCommandSubstitutionDepth: Int

    public init(
        maxCommandCount: Int = 10_000,
        maxFunctionDepth: Int = 100,
        maxLoopIterations: Int = 10_000,
        maxCommandSubstitutionDepth: Int = 32
    ) {
        self.maxCommandCount = maxCommandCount
        self.maxFunctionDepth = maxFunctionDepth
        self.maxLoopIterations = maxLoopIterations
        self.maxCommandSubstitutionDepth = maxCommandSubstitutionDepth
    }
}

public enum SessionLayout: Sendable {
    case unixLike
    case rootOnly
}

public enum SecretHandlingPolicy: Sendable {
    case off
    case resolveAndRedact
    case strict
}

public protocol SecretReferenceResolving: Sendable {
    func resolveSecretReference(_ reference: String) async throws -> Data
}

public struct SecretRedactionReplacement: Sendable, Hashable {
    public var secret: Data
    public var replacement: Data

    public init(secret: Data, replacement: Data) {
        self.secret = secret
        self.replacement = replacement
    }
}

public protocol SecretOutputRedacting: Sendable {
    func redact(
        data: Data,
        replacements: [SecretRedactionReplacement]
    ) -> Data
}

public struct DefaultSecretOutputRedactor: SecretOutputRedacting {
    public static let defaultReplacement = Data("<redacted:secret>".utf8)

    public init() {}

    public func redact(
        data: Data,
        replacements: [SecretRedactionReplacement]
    ) -> Data {
        guard !data.isEmpty, !replacements.isEmpty else {
            return data
        }

        let deduplicated = Set(replacements)
            .filter { !$0.secret.isEmpty }
            .sorted {
                if $0.secret.count == $1.secret.count {
                    return $0.secret.lexicographicallyPrecedes($1.secret)
                }
                return $0.secret.count > $1.secret.count
            }

        guard !deduplicated.isEmpty else {
            return data
        }

        var redacted = data
        for replacement in deduplicated {
            redacted = redacted.replacingOccurrences(
                of: replacement.secret,
                with: replacement.replacement
            )
        }
        return redacted
    }
}

public struct SessionOptions: Sendable {
    public var filesystem: any ShellFilesystem
    public var layout: SessionLayout
    public var initialEnvironment: [String: String]
    public var enableGlobbing: Bool
    public var maxHistory: Int
    public var networkPolicy: NetworkPolicy
    public var executionLimits: ExecutionLimits
    public var permissionHandler: (@Sendable (PermissionRequest) async -> PermissionDecision)?
    public var secretPolicy: SecretHandlingPolicy
    public var secretResolver: (any SecretReferenceResolving)?
    public var secretOutputRedactor: any SecretOutputRedacting

    public init(
        filesystem: any ShellFilesystem = ReadWriteFilesystem(),
        layout: SessionLayout = .unixLike,
        initialEnvironment: [String: String] = [:],
        enableGlobbing: Bool = true,
        maxHistory: Int = 1_000,
        networkPolicy: NetworkPolicy = .disabled,
        executionLimits: ExecutionLimits = .default,
        permissionHandler: (@Sendable (PermissionRequest) async -> PermissionDecision)? = nil,
        secretPolicy: SecretHandlingPolicy = .off,
        secretResolver: (any SecretReferenceResolving)? = nil,
        secretOutputRedactor: any SecretOutputRedacting = DefaultSecretOutputRedactor()
    ) {
        self.filesystem = filesystem
        self.layout = layout
        self.initialEnvironment = initialEnvironment
        self.enableGlobbing = enableGlobbing
        self.maxHistory = maxHistory
        self.networkPolicy = networkPolicy
        self.executionLimits = executionLimits
        self.permissionHandler = permissionHandler
        self.secretPolicy = secretPolicy
        self.secretResolver = secretResolver
        self.secretOutputRedactor = secretOutputRedactor
    }
}

public enum ShellError: Error, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case parserError(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            if path.contains("\u{0}") {
                return "path contains null byte"
            }
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

actor SecretExposureTracker {
    private var replacements: Set<SecretRedactionReplacement> = []

    func record(secret: Data, replacement: Data?) {
        guard !secret.isEmpty else {
            return
        }

        let output = replacement ?? DefaultSecretOutputRedactor.defaultReplacement
        replacements.insert(
            SecretRedactionReplacement(secret: secret, replacement: output)
        )
    }

    func snapshot() -> [SecretRedactionReplacement] {
        Array(replacements)
    }
}

private extension Data {
    func replacingOccurrences(of target: Data, with replacement: Data) -> Data {
        guard !target.isEmpty else {
            return self
        }

        var output = Data()
        var searchRangeStart = startIndex
        let end = endIndex

        while searchRangeStart < end,
              let range = self.range(
                  of: target,
                  options: [],
                  in: searchRangeStart..<end
              ) {
            output.append(self[searchRangeStart..<range.lowerBound])
            output.append(replacement)
            searchRangeStart = range.upperBound
        }

        output.append(self[searchRangeStart..<end])
        return output
    }
}
