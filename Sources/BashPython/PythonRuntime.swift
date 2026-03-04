import Foundation
import Bash

public enum PythonExecutionMode: String, Sendable {
    case code
    case module
}

public struct PythonExecutionRequest: Sendable {
    public var mode: PythonExecutionMode
    public var source: String
    public var scriptPath: String?
    public var arguments: [String]
    public var currentDirectory: String
    public var environment: [String: String]
    public var stdin: String

    public init(
        mode: PythonExecutionMode,
        source: String,
        scriptPath: String?,
        arguments: [String],
        currentDirectory: String,
        environment: [String: String],
        stdin: String
    ) {
        self.mode = mode
        self.source = source
        self.scriptPath = scriptPath
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.stdin = stdin
    }
}

public struct PythonExecutionResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol PythonRuntime: Sendable {
    func execute(
        request: PythonExecutionRequest,
        filesystem: any ShellFilesystem
    ) async -> PythonExecutionResult

    func versionString() async -> String
}

public extension PythonRuntime {
    func versionString() async -> String {
        "Python 3"
    }
}

public actor PythonRuntimeRegistry {
    public static let shared = PythonRuntimeRegistry()

    private var runtime: any PythonRuntime

    public init(runtime: (any PythonRuntime)? = nil) {
        self.runtime = runtime ?? CPythonRuntime()
    }

    public func setRuntime(_ runtime: any PythonRuntime) {
        self.runtime = runtime
    }

    public func currentRuntime() -> any PythonRuntime {
        runtime
    }

    public func resetToDefault() {
        runtime = CPythonRuntime()
    }
}

public enum BashPython {
    public static func setRuntime(_ runtime: any PythonRuntime) async {
        await PythonRuntimeRegistry.shared.setRuntime(runtime)
    }

    public static func setCPythonRuntime(configuration: CPythonConfiguration = .default) async {
        await PythonRuntimeRegistry.shared.setRuntime(CPythonRuntime(configuration: configuration))
    }

    public static func isCPythonRuntimeAvailable() -> Bool {
        CPythonRuntime.isAvailable()
    }

    public static func resetRuntime() async {
        await PythonRuntimeRegistry.shared.resetToDefault()
    }
}

struct UnsupportedPythonRuntime: PythonRuntime {
    let message: String

    init(message: String) {
        self.message = message
    }

    func execute(
        request: PythonExecutionRequest,
        filesystem: any ShellFilesystem
    ) async -> PythonExecutionResult {
        _ = request
        _ = filesystem
        return PythonExecutionResult(
            stdout: "",
            stderr: "python3: \(message)\n",
            exitCode: 1
        )
    }

    func versionString() async -> String {
        "Python 3 (unavailable: \(message))"
    }
}
