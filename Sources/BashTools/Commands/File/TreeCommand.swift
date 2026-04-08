import ArgumentParser
import Foundation
import BashCore

struct TreeCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Include entries starting with .")
        var a = false

        @Option(name: .customShort("L"), help: "Descend only level directories deep")
        var level: Int?

        @Argument(help: "Path to render")
        var path: String = "."
    }

    static let name = "tree"
    static let overview = "List contents of directories in a tree-like format"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if let level = options.level, level < 0 {
            context.writeStderr("tree: level must be >= 0\n")
            return 1
        }

        let resolved = context.resolvePath(options.path)
        let displayName: String
        if options.path == "." {
            displayName = "."
        } else if options.path == "/" || resolved == "/" {
            displayName = "/"
        } else {
            displayName = WorkspacePath.basename(options.path)
        }

        do {
            let lines = try await collectLines(
                path: resolved,
                displayName: displayName,
                depth: 0,
                maxDepth: options.level,
                includeHidden: options.a,
                filesystem: context.filesystem
            )
            context.writeStdout(lines.joined(separator: "\n"))
            context.writeStdout("\n")
            return 0
        } catch {
            context.writeStderr("tree: \(options.path): \(error)\n")
            return 1
        }
    }

    private static func collectLines(
        path: WorkspacePath,
        displayName: String,
        depth: Int,
        maxDepth: Int?,
        includeHidden: Bool,
        filesystem: any FileSystem
    ) async throws -> [String] {
        var lines = [String(repeating: "  ", count: depth) + displayName]
        let info = try await filesystem.stat(path: path)
        guard info.isDirectory else {
            return lines
        }

        if let maxDepth, depth >= maxDepth {
            return lines
        }

        let children = try await filesystem.listDirectory(path: path)
            .filter { includeHidden || !$0.name.hasPrefix(".") }
            .sorted { $0.name < $1.name }

        for child in children {
            lines.append(
                contentsOf: try await collectLines(
                    path: path.appending(child.name),
                    displayName: child.name,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    includeHidden: includeHidden,
                    filesystem: filesystem
                )
            )
        }

        return lines
    }
}
