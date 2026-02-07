import ArgumentParser
import Foundation

private enum CommandIO {
    static func decodeLines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func decodeString(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func encode(_ string: String) -> Data {
        Data(string.utf8)
    }
}

private enum CommandFS {
    static func readInputs(
        paths: [String],
        context: inout CommandContext
    ) async -> (contents: [String], hadError: Bool) {
        if paths.isEmpty {
            return ([CommandIO.decodeString(context.stdin)], false)
        }

        var contents: [String] = []
        var failed = false
        for path in paths {
            let resolved = context.resolvePath(path)
            do {
                let data = try await context.filesystem.readFile(path: resolved)
                contents.append(CommandIO.decodeString(data))
            } catch {
                context.writeStderr("\(path): \(error)\n")
                failed = true
            }
        }
        return (contents, failed)
    }

    static func recursiveSize(of path: String, filesystem: any ShellFilesystem) async throws -> UInt64 {
        let info = try await filesystem.stat(path: path)
        if !info.isDirectory {
            return info.size
        }

        var total: UInt64 = 0
        let children = try await filesystem.listDirectory(path: path)
        for child in children {
            total += try await recursiveSize(of: PathUtils.join(path, child.name), filesystem: filesystem)
        }
        return total
    }

    static func walk(path: String, filesystem: any ShellFilesystem) async throws -> [String] {
        var output = [path]
        let info = try await filesystem.stat(path: path)
        guard info.isDirectory else {
            return output
        }

        let children = try await filesystem.listDirectory(path: path)
        for child in children {
            let childPath = PathUtils.join(path, child.name)
            output.append(contentsOf: try await walk(path: childPath, filesystem: filesystem))
        }
        return output
    }

    static func parseFieldList(_ value: String) -> Set<Int> {
        var output: Set<Int> = []
        for part in value.split(separator: ",") {
            let token = String(part)
            if token.contains("-") {
                let pieces = token.split(separator: "-", maxSplits: 1).map(String.init)
                guard pieces.count == 2,
                      let low = Int(pieces[0]),
                      let high = Int(pieces[1]),
                      low > 0,
                      high >= low else {
                    continue
                }
                for value in low...high {
                    output.insert(value)
                }
            } else if let numeric = Int(token), numeric > 0 {
                output.insert(numeric)
            }
        }
        return output
    }

    static func wildcardMatch(pattern: String, value: String) -> Bool {
        let regexString = PathUtils.globToRegex(pattern)
        guard let regex = try? NSRegularExpression(pattern: regexString) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

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
                            let mode = String(entry.info.permissions, radix: 8)
                            context.writeStdout("\(mode) \(entry.info.size) \(entry.name)\n")
                        }
                    } else {
                        context.writeStdout(filtered.map(\ .name).joined(separator: " "))
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
                context.writeStdout("  Mode: \(String(info.permissions, radix: 8))\n")
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

struct GrepCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Ignore case distinctions")
        var i = false

        @Flag(name: .short, help: "Invert match")
        var v = false

        @Flag(name: .short, help: "Prefix each line with line number")
        var n = false

        @Argument(help: "Pattern and optional files")
        var values: [String] = []
    }

    static let name = "grep"
    static let aliases = ["egrep", "fgrep"]
    static let overview = "Print lines matching a pattern"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard let pattern = options.values.first else {
            context.writeStderr("grep: missing pattern\n")
            return 2
        }

        let files = Array(options.values.dropFirst())
        let inputs = await CommandFS.readInputs(paths: files, context: &context)

        var foundMatch = false
        for (fileIndex, content) in inputs.contents.enumerated() {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (lineIndex, line) in lines.enumerated() {
                let haystack = options.i ? line.lowercased() : line
                let needle = options.i ? pattern.lowercased() : pattern
                let matches = haystack.contains(needle)
                let shouldEmit = options.v ? !matches : matches
                guard shouldEmit else { continue }

                foundMatch = true
                var prefix = ""
                if !files.isEmpty {
                    prefix += "\(files[fileIndex]):"
                }
                if options.n {
                    prefix += "\(lineIndex + 1):"
                }

                context.writeStdout("\(prefix)\(line)\n")
            }
        }

        if inputs.hadError {
            return 2
        }

        return foundMatch ? 0 : 1
    }
}

struct HeadCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Print the first N lines")
        var n: Int = 10

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "head"
    static let overview = "Output the first part of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        for (index, content) in inputs.contents.enumerated() {
            if options.files.count > 1 {
                context.writeStdout("==> \(options.files[index]) <==\n")
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.prefix(max(options.n, 0)) {
                context.writeStdout("\(line)\n")
            }
        }
        return inputs.hadError ? 1 : 0
    }
}

struct TailCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Print the last N lines")
        var n: Int = 10

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "tail"
    static let overview = "Output the last part of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        for (index, content) in inputs.contents.enumerated() {
            if options.files.count > 1 {
                context.writeStdout("==> \(options.files[index]) <==\n")
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.suffix(max(options.n, 0)) {
                context.writeStdout("\(line)\n")
            }
        }
        return inputs.hadError ? 1 : 0
    }
}

struct WcCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Print line counts")
        var l = false

        @Flag(name: .short, help: "Print word counts")
        var w = false

        @Flag(name: .short, help: "Print byte counts")
        var c = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "wc"
    static let overview = "Print newline, word, and byte counts"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let showAll = !options.l && !options.w && !options.c

        var totalLines = 0
        var totalWords = 0
        var totalBytes = 0

        for (index, content) in inputs.contents.enumerated() {
            let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
            let wordCount = content.split { $0.isWhitespace }.count
            let byteCount = content.lengthOfBytes(using: .utf8)

            totalLines += lineCount
            totalWords += wordCount
            totalBytes += byteCount

            var values: [String] = []
            if showAll || options.l { values.append("\(lineCount)") }
            if showAll || options.w { values.append("\(wordCount)") }
            if showAll || options.c { values.append("\(byteCount)") }

            let suffix = options.files.isEmpty ? "" : " \(options.files[index])"
            context.writeStdout(values.joined(separator: " ") + suffix + "\n")
        }

        if inputs.contents.count > 1 {
            var values: [String] = []
            if showAll || options.l { values.append("\(totalLines)") }
            if showAll || options.w { values.append("\(totalWords)") }
            if showAll || options.c { values.append("\(totalBytes)") }
            context.writeStdout(values.joined(separator: " ") + " total\n")
        }

        return inputs.hadError ? 1 : 0
    }
}

struct SortCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Reverse the result")
        var r = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "sort"
    static let overview = "Sort lines of text"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let lines = inputs.contents.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        let sorted = options.r ? lines.sorted(by: >) : lines.sorted()
        for line in sorted {
            context.writeStdout("\(line)\n")
        }
        return inputs.hadError ? 1 : 0
    }
}

struct UniqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Prefix lines by occurrence counts")
        var c = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "uniq"
    static let overview = "Report or omit repeated lines"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)
        let lines = inputs.contents.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

        var previous: String?
        var count = 0

        func flushLine(_ line: String?, count: Int, context: inout CommandContext) {
            guard let line else { return }
            if options.c {
                context.writeStdout("\(count) \(line)\n")
            } else {
                context.writeStdout("\(line)\n")
            }
        }

        for line in lines {
            if line == previous {
                count += 1
            } else {
                flushLine(previous, count: count, context: &context)
                previous = line
                count = 1
            }
        }

        flushLine(previous, count: count, context: &context)
        return inputs.hadError ? 1 : 0
    }
}

struct CutCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .short, help: "Use DELIM instead of TAB")
        var d: String = "\t"

        @Option(name: .short, help: "Select only these fields")
        var f: String

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "cut"
    static let overview = "Remove sections from each line of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let fields = CommandFS.parseFieldList(options.f)
        guard !fields.isEmpty else {
            context.writeStderr("cut: invalid field list\n")
            return 1
        }

        let delimiter = options.d
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)

        for content in inputs.contents {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for line in lines {
                let parts = line.components(separatedBy: delimiter)
                var selected: [String] = []
                for (index, part) in parts.enumerated() where fields.contains(index + 1) {
                    selected.append(part)
                }
                context.writeStdout(selected.joined(separator: delimiter) + "\n")
            }
        }

        return inputs.hadError ? 1 : 0
    }
}

struct TrCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Characters to replace")
        var source: String

        @Argument(help: "Replacement characters")
        var destination: String
    }

    static let name = "tr"
    static let overview = "Translate or delete characters"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let input = CommandIO.decodeString(context.stdin)
        let source = Array(options.source)
        let destination = Array(options.destination)

        let translated = String(input.map { char in
            guard let index = source.firstIndex(of: char) else {
                return char
            }
            if destination.isEmpty {
                return char
            }
            let dest = destination[min(index, destination.count - 1)]
            return dest
        })

        context.writeStdout(translated)
        return 0
    }
}

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

        @Argument(help: "Path")
        var path: String = "."
    }

    static let name = "find"
    static let overview = "Search for files in a directory hierarchy"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let root = context.resolvePath(options.path)
        do {
            let entries = try await CommandFS.walk(path: root, filesystem: context.filesystem)
            for entry in entries {
                if let pattern = options.name {
                    let base = PathUtils.basename(entry)
                    guard CommandFS.wildcardMatch(pattern: pattern, value: base) else {
                        continue
                    }
                }
                context.writeStdout("\(entry)\n")
            }
            return 0
        } catch {
            context.writeStderr("find: \(error)\n")
            return 1
        }
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

struct ClearCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "clear"
    static let overview = "Clear the terminal screen"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        context.writeStdout("\u{001B}[2J\u{001B}[H")
        return 0
    }
}

struct DateCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Use UTC")
        var u = false
    }

    static let name = "date"
    static let overview = "Display current date and time"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = options.u ? TimeZone(secondsFromGMT: 0) : .current
        context.writeStdout("\(formatter.string(from: Date()))\n")
        return 0
    }
}

struct FalseCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "false"
    static let overview = "Return unsuccessful status"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        return 1
    }
}

struct HelpCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "help"
    static let overview = "Display information about builtin commands"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = options
        let commands = Set(context.availableCommands).sorted()
        for command in commands {
            context.writeStdout("\(command)\n")
        }
        return 0
    }
}

struct HistoryCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .shortAndLong, help: "Show only the last N entries")
        var n: Int?
    }

    static let name = "history"
    static let overview = "Display command history"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let entries: ArraySlice<String>
        if let count = options.n, count >= 0 {
            entries = context.history.suffix(count)
        } else {
            entries = context.history[...]
        }

        var index = context.history.count - entries.count + 1
        for line in entries {
            context.writeStdout("\(index)  \(line)\n")
            index += 1
        }
        return 0
    }
}

struct SeqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Stop or start/stop/step values")
        var values: [String] = []
    }

    static let name = "seq"
    static let overview = "Print a sequence of numbers"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let numbers = options.values.compactMap(Double.init)
        let start: Double
        let step: Double
        let end: Double

        switch numbers.count {
        case 1:
            start = 1
            step = 1
            end = numbers[0]
        case 2:
            start = numbers[0]
            step = 1
            end = numbers[1]
        case 3:
            start = numbers[0]
            step = numbers[1]
            end = numbers[2]
        default:
            context.writeStderr("seq: expected 1, 2, or 3 numeric arguments\n")
            return 1
        }

        if step == 0 {
            context.writeStderr("seq: step cannot be 0\n")
            return 1
        }

        var current = start
        if step > 0 {
            while current <= end {
                context.writeStdout(Self.formatNumber(current) + "\n")
                current += step
            }
        } else {
            while current >= end {
                context.writeStdout(Self.formatNumber(current) + "\n")
                current += step
            }
        }

        return 0
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

struct SleepCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Number of seconds to sleep")
        var seconds: Double
    }

    static let name = "sleep"
    static let overview = "Delay for a specified amount of time"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        let nanos = UInt64(max(0, options.seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        return 0
    }
}

struct TrueCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    static let name = "true"
    static let overview = "Return successful status"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        _ = context
        _ = options
        return 0
    }
}

struct WhichCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Command names")
        var names: [String] = []
    }

    static let name = "which"
    static let overview = "Locate a command"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.names.isEmpty else {
            context.writeStderr("which: missing command name\n")
            return 1
        }

        let available = Set(context.availableCommands)
        var failed = false

        for name in options.names {
            if available.contains(name) {
                context.writeStdout("/bin/\(name)\n")
            } else {
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}

extension BashSession {
    func registerDefaultCommands() async {
        let defaults: [any BuiltinCommand.Type] = [
            CatCommand.self,
            CpCommand.self,
            LnCommand.self,
            LsCommand.self,
            MkdirCommand.self,
            MvCommand.self,
            ReadlinkCommand.self,
            RmCommand.self,
            RmdirCommand.self,
            StatCommand.self,
            TouchCommand.self,
            GrepCommand.self,
            HeadCommand.self,
            TailCommand.self,
            WcCommand.self,
            SortCommand.self,
            UniqCommand.self,
            CutCommand.self,
            TrCommand.self,
            BasenameCommand.self,
            CdCommand.self,
            DirnameCommand.self,
            DuCommand.self,
            EchoCommand.self,
            EnvCommand.self,
            ExportCommand.self,
            FindCommand.self,
            PrintenvCommand.self,
            PwdCommand.self,
            TeeCommand.self,
            ClearCommand.self,
            DateCommand.self,
            FalseCommand.self,
            HelpCommand.self,
            HistoryCommand.self,
            SeqCommand.self,
            SleepCommand.self,
            TrueCommand.self,
            WhichCommand.self,
        ]

        for command in defaults {
            await register(command)
        }
    }
}
