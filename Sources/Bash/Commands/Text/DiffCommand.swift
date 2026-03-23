import ArgumentParser
import Foundation
import Workspace

struct DiffCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Recursively compare any subdirectories found")
        var r = false

        @Flag(name: .short, help: "Output unified context")
        var u = false

        @Argument(help: "Two files or directories to compare")
        var paths: [String] = []
    }

    static let name = "diff"
    static let overview = "Compare files line by line"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.paths.count == 2 else {
            context.writeStderr("diff: expected exactly two file operands\n")
            return 2
        }

        let leftName = options.paths[0]
        let rightName = options.paths[1]
        let leftPath = context.resolvePath(leftName)
        let rightPath = context.resolvePath(rightName)

        do {
            let leftInfo = try await context.filesystem.stat(path: leftPath)
            let rightInfo = try await context.filesystem.stat(path: rightPath)

            if leftInfo.isDirectory || rightInfo.isDirectory {
                guard leftInfo.isDirectory, rightInfo.isDirectory else {
                    context.writeStderr("diff: cannot compare file with directory\n")
                    return 2
                }
                guard options.r else {
                    context.writeStderr("diff: \(leftName) \(rightName): common subdirectories\n")
                    return 2
                }

                let different = try await compareDirectories(
                    leftRoot: leftPath,
                    rightRoot: rightPath,
                    leftLabel: leftName,
                    rightLabel: rightName,
                    unified: options.u,
                    context: &context
                )
                return different ? 1 : 0
            }

            let different = try await compareFiles(
                leftPath: leftPath,
                rightPath: rightPath,
                leftLabel: leftName,
                rightLabel: rightName,
                unified: options.u,
                context: &context
            )
            return different ? 1 : 0
        } catch {
            context.writeStderr("diff: \(error)\n")
            return 2
        }
    }

    private static func compareDirectories(
        leftRoot: String,
        rightRoot: String,
        leftLabel: String,
        rightLabel: String,
        unified: Bool,
        context: inout CommandContext
    ) async throws -> Bool {
        let leftEntries = try await recursiveEntryMap(root: leftRoot, filesystem: context.filesystem)
        let rightEntries = try await recursiveEntryMap(root: rightRoot, filesystem: context.filesystem)
        let allKeys = Set(leftEntries.keys).union(rightEntries.keys).sorted()

        var different = false

        for key in allKeys {
            let left = leftEntries[key]
            let right = rightEntries[key]

            switch (left, right) {
            case let (.some(leftInfo), .some(rightInfo)):
                if leftInfo.isDirectory && rightInfo.isDirectory {
                    continue
                }

                if leftInfo.isDirectory != rightInfo.isDirectory {
                    context.writeStdout("File \(leftLabel)/\(key) and \(rightLabel)/\(key) differ\n")
                    different = true
                    continue
                }

                let fileDifferent = try await compareFiles(
                    leftPath: PathUtils.join(leftRoot, key),
                    rightPath: PathUtils.join(rightRoot, key),
                    leftLabel: "\(leftLabel)/\(key)",
                    rightLabel: "\(rightLabel)/\(key)",
                    unified: unified,
                    context: &context
                )
                different = different || fileDifferent
            case (.some, .none):
                context.writeStdout("Only in \(leftLabel): \(key)\n")
                different = true
            case (.none, .some):
                context.writeStdout("Only in \(rightLabel): \(key)\n")
                different = true
            case (.none, .none):
                continue
            }
        }

        return different
    }

    private static func recursiveEntryMap(
        root: String,
        filesystem: any ShellFilesystem
    ) async throws -> [String: FileInfo] {
        let entries = try await CommandFS.walk(path: root, filesystem: filesystem)
        var map: [String: FileInfo] = [:]
        for entry in entries where entry != root {
            let info = try await filesystem.stat(path: entry)
            let relative = String(entry.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !relative.isEmpty {
                map[relative] = info
            }
        }
        return map
    }

    private static func compareFiles(
        leftPath: String,
        rightPath: String,
        leftLabel: String,
        rightLabel: String,
        unified: Bool,
        context: inout CommandContext
    ) async throws -> Bool {
        let leftData = try await context.filesystem.readFile(path: leftPath)
        let rightData = try await context.filesystem.readFile(path: rightPath)

        let leftLines = normalizedLines(from: CommandIO.decodeString(leftData))
        let rightLines = normalizedLines(from: CommandIO.decodeString(rightData))
        guard leftLines != rightLines else {
            return false
        }

        if unified {
            context.writeStdout("--- \(leftLabel)\n")
            context.writeStdout("+++ \(rightLabel)\n")
            context.writeStdout("@@ -1,\(leftLines.count) +1,\(rightLines.count) @@\n")
        } else {
            context.writeStdout("--- \(leftLabel)\n")
            context.writeStdout("+++ \(rightLabel)\n")
        }

        let maxCount = max(leftLines.count, rightLines.count)
        for index in 0..<maxCount {
            let left = index < leftLines.count ? leftLines[index] : nil
            let right = index < rightLines.count ? rightLines[index] : nil

            if unified {
                if left == right, let left {
                    context.writeStdout(" \(left)\n")
                    continue
                }
            } else if left == right {
                continue
            }

            if let left {
                context.writeStdout("-\(left)\n")
            }
            if let right {
                context.writeStdout("+\(right)\n")
            }
        }

        return true
    }

    private static func normalizedLines(from string: String) -> [String] {
        if string.isEmpty {
            return []
        }
        var lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if string.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
