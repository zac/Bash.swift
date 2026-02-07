import ArgumentParser
import Foundation

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

struct RgCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Ignore case distinctions")
        var i = false

        @Flag(name: .short, help: "Smart case (ignore case unless pattern has uppercase characters)")
        var S = false

        @Flag(name: .short, help: "Interpret pattern as a literal string")
        var F = false

        @Flag(name: .short, help: "Prefix each line with line number")
        var n = false

        @Flag(name: .short, help: "Show only paths with matching lines")
        var l = false

        @Flag(name: .short, help: "Show count of matching lines per file")
        var c = false

        @Option(name: .short, help: "Show NUM lines of context after each match")
        var A: Int = 0

        @Option(name: .short, help: "Show NUM lines of context before each match")
        var B: Int = 0

        @Option(name: .short, help: "Show NUM lines of context before and after each match")
        var C: Int?

        @Flag(name: .long, help: "Include hidden files and directories")
        var hidden = false

        @Flag(name: .long, help: "Print files that would be searched")
        var files = false

        @Option(name: [.customShort("g"), .customLong("glob")], help: "Include only files whose path matches the glob")
        var globs: [String] = []

        @Argument(help: "Pattern and optional paths, or paths for --files")
        var values: [String] = []
    }

    static let name = "rg"
    static let overview = "Search recursively for a regex pattern"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.C != nil, (options.A != 0 || options.B != 0) {
            context.writeStderr("rg: cannot combine -C with -A or -B\n")
            return 2
        }

        if options.c && options.l {
            context.writeStderr("rg: cannot combine -c and -l\n")
            return 2
        }

        if options.A < 0 || options.B < 0 || (options.C ?? 0) < 0 {
            context.writeStderr("rg: context values must be >= 0\n")
            return 2
        }

        let afterContext = options.C ?? options.A
        let beforeContext = options.C ?? options.B

        let pattern: String?
        let roots: [String]
        if options.files {
            pattern = nil
            roots = options.values.isEmpty ? ["."] : options.values
        } else {
            guard let rawPattern = options.values.first else {
                context.writeStderr("rg: missing pattern\n")
                return 2
            }
            pattern = rawPattern
            roots = options.values.count > 1 ? Array(options.values.dropFirst()) : ["."]
        }

        let candidate = await collectCandidateFiles(
            roots: roots,
            includeHidden: options.hidden,
            globs: options.globs,
            context: &context
        )
        if candidate.hadError {
            return 2
        }

        if options.files {
            for file in candidate.files {
                context.writeStdout("\(file.displayPath)\n")
            }
            return 0
        }

        guard let pattern else {
            return 2
        }

        let ignoreCase = options.i || (options.S && !containsUppercase(pattern))

        let matcher: Matcher
        if options.F {
            matcher = .fixedString(pattern: pattern, ignoreCase: ignoreCase)
        } else {
            let regexOptions: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
            } catch {
                context.writeStderr("rg: invalid regex: \(pattern)\n")
                return 2
            }
            matcher = .regex(regex)
        }

        var foundMatch = false
        var hadError = false

        for candidateFile in candidate.files {
            do {
                let matched = try await searchFile(
                    path: candidateFile.path,
                    displayPath: candidateFile.displayPath,
                    matcher: matcher,
                    includeLineNumbers: options.n,
                    fileNamesOnly: options.l,
                    countOnly: options.c,
                    beforeContext: beforeContext,
                    afterContext: afterContext,
                    context: &context
                )
                foundMatch = foundMatch || matched
            } catch {
                context.writeStderr("rg: \(candidateFile.displayPath): \(error)\n")
                hadError = true
            }
        }

        if hadError {
            return 2
        }
        return foundMatch ? 0 : 1
    }

    private enum Matcher {
        case regex(NSRegularExpression)
        case fixedString(pattern: String, ignoreCase: Bool)

        func matches(line: String) -> Bool {
            switch self {
            case let .regex(regex):
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return regex.firstMatch(in: line, range: range) != nil
            case let .fixedString(pattern, ignoreCase):
                if ignoreCase {
                    return line.lowercased().contains(pattern.lowercased())
                }
                return line.contains(pattern)
            }
        }
    }

    private struct CandidateFile {
        let path: String
        let displayPath: String
    }

    private static func searchFile(
        path: String,
        displayPath: String,
        matcher: Matcher,
        includeLineNumbers: Bool,
        fileNamesOnly: Bool,
        countOnly: Bool,
        beforeContext: Int,
        afterContext: Int,
        context: inout CommandContext
    ) async throws -> Bool {
        let data = try await context.filesystem.readFile(path: path)
        let content = CommandIO.decodeString(data)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if content.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }

        var matchedIndices: [Int] = []
        for (index, line) in lines.enumerated() where matcher.matches(line: line) {
            matchedIndices.append(index)
        }

        guard !matchedIndices.isEmpty else {
            return false
        }

        if fileNamesOnly {
            context.writeStdout("\(displayPath)\n")
            return true
        }

        if countOnly {
            context.writeStdout("\(displayPath):\(matchedIndices.count)\n")
            return true
        }

        let outputIndices = contextRanges(
            matches: matchedIndices,
            lineCount: lines.count,
            before: beforeContext,
            after: afterContext
        )
        let matchSet = Set(matchedIndices)

        for index in outputIndices {
            let line = lines[index]
            if includeLineNumbers {
                context.writeStdout("\(displayPath):\(index + 1):\(line)\n")
            } else if matchSet.contains(index) {
                context.writeStdout("\(displayPath):\(line)\n")
            } else {
                context.writeStdout("\(displayPath)-\(line)\n")
            }
        }

        return true
    }

    private static func contextRanges(matches: [Int], lineCount: Int, before: Int, after: Int) -> [Int] {
        var included = Set<Int>()
        for match in matches {
            let start = max(0, match - before)
            let end = min(lineCount - 1, match + after)
            for index in start...end {
                included.insert(index)
            }
        }
        return included.sorted()
    }

    private static func collectCandidateFiles(
        roots: [String],
        includeHidden: Bool,
        globs: [String],
        context: inout CommandContext
    ) async -> (files: [CandidateFile], hadError: Bool) {
        var result: [CandidateFile] = []
        var seen = Set<String>()
        var hadError = false

        let globRegexes: [NSRegularExpression] = globs.compactMap { glob in
            try? NSRegularExpression(pattern: PathUtils.globToRegex(glob))
        }

        for root in roots {
            let resolved = context.resolvePath(root)
            do {
                let info = try await context.filesystem.stat(path: resolved)
                if info.isDirectory {
                    let entries = try await CommandFS.walk(path: resolved, filesystem: context.filesystem)
                    for entry in entries where entry != resolved {
                        let entryInfo = try await context.filesystem.stat(path: entry)
                        guard !entryInfo.isDirectory else {
                            continue
                        }
                        guard includeHidden || !isHidden(path: entry) else {
                            continue
                        }
                        guard matchesGlobs(path: entry, globs: globRegexes) else {
                            continue
                        }
                        if seen.insert(entry).inserted {
                            result.append(CandidateFile(path: entry, displayPath: entry))
                        }
                    }
                } else {
                    guard includeHidden || !isHidden(path: resolved) else {
                        continue
                    }
                    guard matchesGlobs(path: resolved, globs: globRegexes) else {
                        continue
                    }
                    if seen.insert(resolved).inserted {
                        result.append(CandidateFile(path: resolved, displayPath: root))
                    }
                }
            } catch {
                context.writeStderr("rg: \(root): \(error)\n")
                hadError = true
            }
        }

        return (result.sorted { $0.displayPath < $1.displayPath }, hadError)
    }

    private static func matchesGlobs(path: String, globs: [NSRegularExpression]) -> Bool {
        guard !globs.isEmpty else {
            return true
        }

        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        for regex in globs where regex.firstMatch(in: path, range: range) != nil {
            return true
        }
        return false
    }

    private static func isHidden(path: String) -> Bool {
        PathUtils.splitComponents(path).contains { $0.hasPrefix(".") }
    }

    private static func containsUppercase(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }
}

