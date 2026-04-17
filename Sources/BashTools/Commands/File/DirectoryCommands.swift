import ArgumentParser
import Foundation
import BashCore

struct LsCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Use a long listing format")
        var long = false

        @Flag(name: .short, help: "Include entries starting with .")
        var all = false

        @Argument(help: "Paths to list")
        var paths: [String] = []
    }

    static let name = "ls"
    static let overview = "List directory contents"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let targets = options.paths.isEmpty ? ["."] : options.paths
        var failed = false

        for (index, path) in targets.enumerated() {
            let resolved = context.resolvePath(path)

            do {
                let info = try await context.filesystem.stat(path: resolved)
                if info.isDirectory {
                    let entries = try await context.filesystem.listDirectory(path: resolved)
                    let filtered = entries.filter { options.all || !$0.name.hasPrefix(".") }

                    if targets.count > 1 {
                        if index > 0 {
                            context.writeStdout("\n")
                        }
                        context.writeStdout("\(path):\n")
                    }

                    if options.long {
                        for entry in filtered {
                            let mode = String(entry.info.permissionBits, radix: 8)
                            context.writeStdout("\(mode) \(entry.info.size) \(entry.name)\n")
                        }
                    } else {
                        context.writeStdout(filtered.map(\.name).joined(separator: " "))
                        context.writeStdout("\n")
                    }
                } else {
                    context.writeStdout("\(path)\n")
                }
            } catch {
                context.writeStderr("ls: \(path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}

struct MkdirCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Create parent directories as needed")
        var p = false

        @Argument(help: "Directories to create")
        var paths: [String] = []
    }

    static let name = "mkdir"
    static let overview = "Create directories"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("mkdir: missing operand\n")
            return 1
        }

        var failed = false
        for path in options.paths {
            do {
                try await context.filesystem.createDirectory(path: context.resolvePath(path), recursive: options.p)
            } catch {
                context.writeStderr("mkdir: \(path): \(error)\n")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}

struct RmdirCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Directories to remove")
        var paths: [String] = []
    }

    static let name = "rmdir"
    static let overview = "Remove empty directories"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("rmdir: missing operand\n")
            return 1
        }

        var failed = false
        for path in options.paths {
            do {
                try await context.filesystem.remove(path: context.resolvePath(path), recursive: false)
            } catch {
                context.writeStderr("rmdir: \(path): \(error)\n")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}
