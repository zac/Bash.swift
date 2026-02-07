import ArgumentParser
import Foundation

struct BasenameCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Paths")
        var paths: [String] = []
    }

    static let name = "basename"
    static let overview = "Strip directory and suffix from filenames"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("basename: missing operand\n")
            return 1
        }
        for path in options.paths {
            context.writeStdout(PathUtils.basename(path) + "\n")
        }
        return 0
    }
}

struct CdCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Directory to change to")
        var path: String?
    }

    static let name = "cd"
    static let overview = "Change current shell directory"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let destination = options.path ?? context.environmentValue("HOME")
        let resolved = context.resolvePath(destination)

        do {
            let info = try await context.filesystem.stat(path: resolved)
            guard info.isDirectory else {
                context.writeStderr("cd: not a directory: \(destination)\n")
                return 1
            }
            context.currentDirectory = resolved
            context.environment["PWD"] = resolved
            return 0
        } catch {
            context.writeStderr("cd: \(destination): \(error)\n")
            return 1
        }
    }
}

struct DirnameCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Paths")
        var paths: [String] = []
    }

    static let name = "dirname"
    static let overview = "Strip last component from file name"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("dirname: missing operand\n")
            return 1
        }

        for path in options.paths {
            context.writeStdout(PathUtils.dirname(path) + "\n")
        }

        return 0
    }
}

struct DuCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Display only a total for each argument")
        var s = false

        @Argument(help: "Paths")
        var paths: [String] = []
    }

    static let name = "du"
    static let overview = "Estimate file space usage"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let paths = options.paths.isEmpty ? ["."] : options.paths
        var failed = false

        for path in paths {
            let resolved = context.resolvePath(path)
            do {
                if options.s {
                    let total = try await CommandFS.recursiveSize(of: resolved, filesystem: context.filesystem)
                    context.writeStdout("\(total)\t\(path)\n")
                } else {
                    let walked = try await CommandFS.walk(path: resolved, filesystem: context.filesystem)
                    for entry in walked {
                        let size = try await CommandFS.recursiveSize(of: entry, filesystem: context.filesystem)
                        context.writeStdout("\(size)\t\(entry)\n")
                    }
                }
            } catch {
                context.writeStderr("du: \(path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}

struct EchoCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Do not output the trailing newline")
        var n = false

        @Argument(help: "Words to print")
        var words: [String] = []
    }

    static let name = "echo"
    static let overview = "Display a line of text"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        context.writeStdout(options.words.joined(separator: " "))
        if !options.n {
            context.writeStdout("\n")
        }
        return 0
    }
}

struct EnvCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "env"
    static let overview = "Run a program in a modified environment"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        for key in context.environment.keys.sorted() {
            context.writeStdout("\(key)=\(context.environment[key] ?? "")\n")
        }
        return 0
    }
}

struct ExportCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Assignments in KEY=VALUE form")
        var values: [String] = []
    }

    static let name = "export"
    static let overview = "Set environment variables"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.values.isEmpty else {
            for key in context.environment.keys.sorted() {
                context.writeStdout("declare -x \(key)=\"\(context.environment[key] ?? "")\"\n")
            }
            return 0
        }

        for assignment in options.values {
            if let equal = assignment.firstIndex(of: "=") {
                let key = String(assignment[..<equal])
                let value = String(assignment[assignment.index(after: equal)...])
                context.environment[key] = value
            } else {
                context.environment[assignment] = context.environment[assignment] ?? ""
            }
        }

        return 0
    }
}

struct FindCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .long, help: "Name pattern")
        var name: String?

        @Option(name: .customLong("type"), help: "Filter by type: f, d, l")
        var type: String?

        @Option(name: .customLong("path"), help: "Path pattern")
        var pathPattern: String?

        @Option(name: .customLong("maxdepth"), help: "Descend at most N levels")
        var maxDepth: Int?

        @Option(name: .customLong("mindepth"), help: "Do not apply tests at levels less than N")
        var minDepth: Int?

        @Flag(name: .customLong("not"), help: "Negate all tests")
        var not = false

        @Argument(help: "Path")
        var path: String = "."
    }

    static let name = "find"
    static let overview = "Search for files in a directory hierarchy"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if let maxDepth = options.maxDepth, maxDepth < 0 {
            context.writeStderr("find: maxdepth must be >= 0\n")
            return 1
        }
        if let minDepth = options.minDepth, minDepth < 0 {
            context.writeStderr("find: mindepth must be >= 0\n")
            return 1
        }
        if let type = options.type, !["f", "d", "l"].contains(type) {
            context.writeStderr("find: unsupported type '\(type)'\n")
            return 1
        }

        let root = context.resolvePath(options.path)
        do {
            let entries = try await CommandFS.walk(path: root, filesystem: context.filesystem)
            let rootDepth = PathUtils.splitComponents(root).count
            for entry in entries {
                let depth = max(0, PathUtils.splitComponents(entry).count - rootDepth)
                if let maxDepth = options.maxDepth, depth > maxDepth {
                    continue
                }
                if let minDepth = options.minDepth, depth < minDepth {
                    continue
                }

                let info = try await context.filesystem.stat(path: entry)
                let matches = try match(entry: entry, info: info, options: options)
                let shouldInclude = options.not ? !matches : matches
                if shouldInclude {
                    context.writeStdout("\(entry)\n")
                }
            }
            return 0
        } catch {
            context.writeStderr("find: \(error)\n")
            return 1
        }
    }

    private static func match(entry: String, info: FileInfo, options: Options) throws -> Bool {
        if let pattern = options.name {
            let base = PathUtils.basename(entry)
            guard CommandFS.wildcardMatch(pattern: pattern, value: base) else {
                return false
            }
        }

        if let pathPattern = options.pathPattern {
            guard CommandFS.wildcardMatch(pattern: pathPattern, value: entry) else {
                return false
            }
        }

        if let type = options.type {
            switch type {
            case "f":
                if info.isDirectory || info.isSymbolicLink {
                    return false
                }
            case "d":
                if !info.isDirectory {
                    return false
                }
            case "l":
                if !info.isSymbolicLink {
                    return false
                }
            default:
                throw ShellError.unsupported("unsupported type")
            }
        }

        return true
    }
}

struct PrintenvCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Environment keys")
        var keys: [String] = []
    }

    static let name = "printenv"
    static let overview = "Print all or part of environment"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.keys.isEmpty {
            for key in context.environment.keys.sorted() {
                context.writeStdout("\(key)=\(context.environment[key] ?? "")\n")
            }
        } else {
            for key in options.keys {
                if let value = context.environment[key] {
                    context.writeStdout("\(value)\n")
                }
            }
        }
        return 0
    }
}

struct PwdCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "pwd"
    static let overview = "Print current working directory"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        context.writeStdout("\(context.currentDirectory)\n")
        return 0
    }
}

struct TeeCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Append to the given files")
        var a = false

        @Argument(help: "Files to write")
        var files: [String] = []
    }

    static let name = "tee"
    static let overview = "Read from stdin and write to stdout and files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let data = context.stdin
        var failed = false

        for file in options.files {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(file),
                    data: data,
                    append: options.a
                )
            } catch {
                context.writeStderr("tee: \(file): \(error)\n")
                failed = true
            }
        }

        context.stdout.append(data)
        return failed ? 1 : 0
    }
}

