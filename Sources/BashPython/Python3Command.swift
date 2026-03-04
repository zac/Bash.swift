import ArgumentParser
import Foundation
import Bash

public struct Python3Command: BuiltinCommand {
    public struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "Arguments")
        public var arguments: [String] = []

        public init() {}
    }

    public static let name = "python3"
    public static let aliases = ["python"]
    public static let overview = "Execute Python code via embedded CPython"

    private static let helpText = """
    OVERVIEW: Execute Python code via embedded CPython

    USAGE: python3 [OPTIONS] [-c CODE | -m MODULE | FILE] [ARGS...]

    OPTIONS:
      -c CODE     Execute CODE as Python script
      -m MODULE   Run library module as a script
      -V, --version  Show Python version
      -h, --help  Show this help

    """

    public static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.arguments.contains("--help") || options.arguments.contains("-h") {
            context.writeStdout(helpText)
            return 0
        }

        let parsed = parseInvocation(options.arguments)
        switch parsed {
        case let .failure(message):
            context.writeStderr(message)
            return 2
        case let .success(invocation):
            if invocation.showVersion {
                let runtime = await PythonRuntimeRegistry.shared.currentRuntime()
                context.writeStdout(await runtime.versionString() + "\n")
                return 0
            }

            let source: String
            let scriptPath: String?

            switch invocation.input {
            case let .code(code):
                source = code
                scriptPath = "-c"
            case let .module(module):
                source = module
                scriptPath = module
            case let .file(path):
                if path == "-" {
                    source = String(decoding: context.stdin, as: UTF8.self)
                    scriptPath = "<stdin>"
                } else {
                    let resolved = context.resolvePath(path)
                    guard await context.filesystem.exists(path: resolved) else {
                        context.writeStderr("python3: can't open file '\(path)': [Errno 2] No such file or directory\n")
                        return 2
                    }

                    do {
                        let data = try await context.filesystem.readFile(path: resolved)
                        source = String(decoding: data, as: UTF8.self)
                        scriptPath = path
                    } catch {
                        context.writeStderr("python3: can't open file '\(path)': \(error)\n")
                        return 2
                    }
                }
            case .stdin:
                source = String(decoding: context.stdin, as: UTF8.self)
                scriptPath = "<stdin>"
            }

            if source.isEmpty {
                context.writeStderr(
                    "python3: no input provided (use -c CODE, -m MODULE, provide a script file, or pipe stdin)\n"
                )
                return 2
            }

            let request = PythonExecutionRequest(
                mode: invocation.input.executionMode,
                source: source,
                scriptPath: scriptPath,
                arguments: invocation.scriptArgs,
                currentDirectory: context.currentDirectory,
                environment: context.environment,
                stdin: String(decoding: context.stdin, as: UTF8.self)
            )

            let runtime = await PythonRuntimeRegistry.shared.currentRuntime()
            let result = await runtime.execute(request: request, filesystem: context.filesystem)
            if !result.stdout.isEmpty {
                context.writeStdout(result.stdout)
            }
            if !result.stderr.isEmpty {
                context.writeStderr(result.stderr)
            }
            return result.exitCode
        }
    }

    private struct Invocation: Sendable {
        enum Input: Sendable {
            case code(String)
            case module(String)
            case file(String)
            case stdin

            var executionMode: PythonExecutionMode {
                switch self {
                case .module:
                    return .module
                default:
                    return .code
                }
            }
        }

        var input: Input
        var scriptArgs: [String]
        var showVersion: Bool
    }

    private enum ParseResult {
        case success(Invocation)
        case failure(String)
    }

    private static func parseInvocation(_ args: [String]) -> ParseResult {
        if args.isEmpty {
            return .success(Invocation(input: .stdin, scriptArgs: [], showVersion: false))
        }

        let index = 0
        while index < args.count {
            let arg = args[index]

            switch arg {
            case "-V", "--version":
                return .success(Invocation(input: .stdin, scriptArgs: [], showVersion: true))
            case "-c":
                guard index + 1 < args.count else {
                    return .failure("python3: option requires an argument -- c\n")
                }
                let code = args[index + 1]
                let scriptArgs = Array(args[(index + 2)...])
                return .success(Invocation(input: .code(code), scriptArgs: scriptArgs, showVersion: false))
            case "-m":
                guard index + 1 < args.count else {
                    return .failure("python3: option requires an argument -- m\n")
                }
                let module = args[index + 1]
                let scriptArgs = Array(args[(index + 2)...])
                return .success(Invocation(input: .module(module), scriptArgs: scriptArgs, showVersion: false))
            case "--":
                guard index + 1 < args.count else {
                    return .success(Invocation(input: .stdin, scriptArgs: [], showVersion: false))
                }
                let script = args[index + 1]
                let scriptArgs = Array(args[(index + 2)...])
                return .success(Invocation(input: .file(script), scriptArgs: scriptArgs, showVersion: false))
            default:
                if arg.hasPrefix("-"), arg != "-" {
                    return .failure("python3: unrecognized option '\(arg)'\n")
                }

                let scriptArgs = Array(args[(index + 1)...])
                return .success(Invocation(input: .file(arg), scriptArgs: scriptArgs, showVersion: false))
            }
        }

        return .success(Invocation(input: .stdin, scriptArgs: [], showVersion: false))
    }
}
