import ArgumentParser
import Foundation
import BashCore

struct CatCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Files to concatenate")
        var files: [String] = []
    }

    static let name = "cat"
    static let overview = "Concatenate files and print on stdout"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.files.isEmpty {
            context.stdout.append(context.stdin)
            return 0
        }

        var failed = false
        for file in options.files {
            do {
                let data = try await context.filesystem.readFile(path: context.resolvePath(file))
                context.stdout.append(data)
            } catch {
                context.writeStderr("\(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}

struct ReadlinkCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Path to symbolic link")
        var path: String
    }

    static let name = "readlink"
    static let overview = "Print resolved symbolic link target"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        do {
            let target = try await context.filesystem.readSymlink(path: context.resolvePath(options.path))
            context.writeStdout("\(target)\n")
            return 0
        } catch {
            context.writeStderr("readlink: \(error)\n")
            return 1
        }
    }
}

struct RmCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.short, .customShort("R")], help: "Remove directories and contents recursively")
        var recursive = false

        @Flag(name: .short, help: "Ignore missing files")
        var force = false

        @Argument(help: "Paths to remove")
        var paths: [String] = []
    }

    static let name = "rm"
    static let overview = "Remove files or directories"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("rm: missing operand\n")
            return 1
        }

        var failed = false
        for path in options.paths {
            do {
                try await context.filesystem.remove(path: context.resolvePath(path), recursive: options.recursive)
            } catch {
                if !options.force {
                    context.writeStderr("rm: \(path): \(error)\n")
                    failed = true
                }
            }
        }

        return failed ? 1 : 0
    }
}

struct StatCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Paths to inspect")
        var paths: [String] = []
    }

    static let name = "stat"
    static let overview = "Display file status"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("stat: missing operand\n")
            return 1
        }

        var failed = false
        for path in options.paths {
            do {
                let info = try await context.filesystem.stat(path: context.resolvePath(path))
                let type = info.isDirectory ? "directory" : (info.isSymbolicLink ? "symlink" : "file")
                context.writeStdout("  File: \(path)\n")
                context.writeStdout("  Size: \(info.size)\n")
                context.writeStdout("  Type: \(type)\n")
                context.writeStdout("  Mode: \(String(info.permissionBits, radix: 8))\n")
            } catch {
                context.writeStderr("stat: \(path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}

struct TouchCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Files to touch")
        var paths: [String] = []
    }

    static let name = "touch"
    static let overview = "Change file timestamps or create empty files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("touch: missing file operand\n")
            return 1
        }

        var failed = false
        for path in options.paths {
            let resolved = context.resolvePath(path)
            do {
                if await context.filesystem.exists(path: resolved) {
                    let existing = try await context.filesystem.readFile(path: resolved)
                    try await context.filesystem.writeFile(path: resolved, data: existing, append: false)
                } else {
                    try await context.filesystem.writeFile(path: resolved, data: Data(), append: false)
                }
            } catch {
                context.writeStderr("touch: \(path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}
