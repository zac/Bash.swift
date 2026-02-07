import ArgumentParser
import Foundation

struct CpCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("R"), .customLong("recursive")], help: "Copy directories recursively")
        var recursive = false

        @Argument(help: "Source and destination")
        var paths: [String] = []
    }

    static let name = "cp"
    static let overview = "Copy files and directories"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.paths.count == 2 else {
            context.writeStderr("cp: expected source and destination\n")
            return 1
        }

        do {
            try await context.filesystem.copy(
                from: context.resolvePath(options.paths[0]),
                to: context.resolvePath(options.paths[1]),
                recursive: options.recursive
            )
            return 0
        } catch {
            context.writeStderr("cp: \(error)\n")
            return 1
        }
    }
}

struct LnCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .shortAndLong, help: "Create symbolic link")
        var symbolic = false

        @Argument(help: "Target and link path")
        var paths: [String] = []
    }

    static let name = "ln"
    static let overview = "Create links between files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.paths.count == 2 else {
            context.writeStderr("ln: expected target and link name\n")
            return 1
        }

        let target = options.paths[0]
        let linkName = context.resolvePath(options.paths[1])

        do {
            if options.symbolic {
                try await context.filesystem.createSymlink(path: linkName, target: target)
            } else {
                try await context.filesystem.copy(
                    from: context.resolvePath(target),
                    to: linkName,
                    recursive: false
                )
            }
            return 0
        } catch {
            context.writeStderr("ln: \(error)\n")
            return 1
        }
    }
}

struct MvCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Source and destination")
        var paths: [String] = []
    }

    static let name = "mv"
    static let overview = "Move or rename files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.paths.count == 2 else {
            context.writeStderr("mv: expected source and destination\n")
            return 1
        }

        do {
            try await context.filesystem.move(
                from: context.resolvePath(options.paths[0]),
                to: context.resolvePath(options.paths[1])
            )
            return 0
        } catch {
            context.writeStderr("mv: \(error)\n")
            return 1
        }
    }
}

