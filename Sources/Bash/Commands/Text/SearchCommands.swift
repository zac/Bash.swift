import ArgumentParser
import Foundation

struct GrepCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Use extended regular expressions")
        var E = false

        @Flag(name: .short, help: "Interpret pattern as a list of fixed strings")
        var F = false

        @Flag(name: .short, help: "Ignore case distinctions")
        var i = false

        @Flag(name: .short, help: "Invert match")
        var v = false

        @Flag(name: .short, help: "Prefix each line with line number")
        var n = false

        @Flag(name: .short, help: "Print only a count of selected lines per file")
        var c = false

        @Flag(name: .short, help: "Print only names of files with selected lines")
        var l = false

        @Flag(name: .customShort("L"), help: "Print only names of files with no matches")
        var L = false

        @Flag(name: .short, help: "Show only the matching parts of matching lines")
        var o = false

        @Flag(name: .short, help: "Select only whole words")
        var w = false

        @Flag(name: .short, help: "Select only whole lines")
        var x = false

        @Flag(name: .short, help: "Recursively search files in directories")
        var r = false

        @Option(name: .short, help: "Pattern to match")
        var e: [String] = []

        @Option(name: .short, help: "Read patterns from file")
        var f: [String] = []

        @Argument(help: "Pattern and optional files")
        var values: [String] = []
    }

    static let name = "grep"
    static let aliases = ["egrep", "fgrep"]
    static let overview = "Print lines matching a pattern"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.l && options.L {
            context.writeStderr("grep: cannot combine -l and -L\n")
            return 2
        }
        if options.c && (options.l || options.L) {
            context.writeStderr("grep: cannot combine -c with -l or -L\n")
            return 2
        }

        var patterns = options.e
        let patternFileRead = await readPatternsFromFiles(paths: options.f, commandName: "grep", context: &context)
        if patternFileRead.hadError {
            return 2
        }
        patterns.append(contentsOf: patternFileRead.patterns)

        let inputPaths: [String]
        if patterns.isEmpty {
            guard let pattern = options.values.first else {
                context.writeStderr("grep: missing pattern\n")
                return 2
            }
            patterns.append(pattern)
            inputPaths = Array(options.values.dropFirst())
        } else {
            inputPaths = options.values
        }

        let effectivePaths: [String]
        if options.r && inputPaths.isEmpty {
            effectivePaths = ["."]
        } else {
            effectivePaths = inputPaths
        }

        let useFixedStrings = options.F || context.commandName == "fgrep"
        let matcher: SearchMatcher
        do {
            matcher = try SearchMatcher.make(
                commandName: "grep",
                patterns: patterns,
                fixedStrings: useFixedStrings,
                ignoreCase: options.i,
                wordMatch: options.w,
                fullLineMatch: options.x
            )
        } catch let error as SearchMatcherBuildError {
            context.writeStderr("\(error.message)\n")
            return 2
        } catch {
            context.writeStderr("grep: failed to build matcher\n")
            return 2
        }

        var hadError = false
        var selectedFound = false
        let searchTargets: [SearchFileTarget]
        if effectivePaths.isEmpty {
            searchTargets = []
        } else {
            let discovered = await collectGrepTargets(paths: effectivePaths, recursive: options.r, context: &context)
            searchTargets = discovered.targets
            hadError = discovered.hadError
        }

        if effectivePaths.isEmpty {
            let selected = processGrepContent(
                content: CommandIO.decodeString(context.stdin),
                displayPath: "(standard input)",
                includeFilePrefix: false,
                options: options,
                matcher: matcher,
                context: &context
            )
            selectedFound = selectedFound || selected
        } else {
            let includeFilePrefix = searchTargets.count > 1
            for target in searchTargets {
                do {
                    let data = try await context.filesystem.readFile(path: target.path)
                    let selected = processGrepContent(
                        content: CommandIO.decodeString(data),
                        displayPath: target.displayPath,
                        includeFilePrefix: includeFilePrefix,
                        options: options,
                        matcher: matcher,
                        context: &context
                    )
                    selectedFound = selectedFound || selected
                } catch {
                    context.writeStderr("grep: \(target.displayPath): \(error)\n")
                    hadError = true
                }
            }
        }

        if hadError {
            return 2
        }

        return selectedFound ? 0 : 1
    }

    private static func processGrepContent(
        content: String,
        displayPath: String,
        includeFilePrefix: Bool,
        options: Options,
        matcher: SearchMatcher,
        context: inout CommandContext
    ) -> Bool {
        let lines = CommandIO.splitLines(content)
        var rawMatchCount = 0
        var selectedLineCount = 0
        let printOnlyMatches = options.o && !options.v && !options.c && !options.l && !options.L

        for (lineIndex, line) in lines.enumerated() {
            let matchRanges = matcher.matchRanges(in: line)
            let rawMatches = !matchRanges.isEmpty
            let selected = options.v ? !rawMatches : rawMatches
            guard selected else {
                continue
            }

            selectedLineCount += 1
            if rawMatches {
                rawMatchCount += 1
            }

            if printOnlyMatches {
                for range in matchRanges {
                    let prefix = grepPrefix(
                        includeFilePrefix: includeFilePrefix,
                        displayPath: displayPath,
                        includeLineNumber: options.n,
                        lineNumber: lineIndex + 1
                    )
                    context.writeStdout(prefix + line[range] + "\n")
                }
                continue
            }

            if options.c || options.l || options.L {
                continue
            }

            let prefix = grepPrefix(
                includeFilePrefix: includeFilePrefix,
                displayPath: displayPath,
                includeLineNumber: options.n,
                lineNumber: lineIndex + 1
            )
            context.writeStdout(prefix + line + "\n")
        }

        if options.c {
            if includeFilePrefix {
                context.writeStdout("\(displayPath):\(selectedLineCount)\n")
            } else {
                context.writeStdout("\(selectedLineCount)\n")
            }
        } else if options.l, selectedLineCount > 0 {
            context.writeStdout("\(displayPath)\n")
        } else if options.L, rawMatchCount == 0 {
            context.writeStdout("\(displayPath)\n")
        }

        if options.L {
            return rawMatchCount == 0
        }
        return selectedLineCount > 0
    }

    private static func grepPrefix(
        includeFilePrefix: Bool,
        displayPath: String,
        includeLineNumber: Bool,
        lineNumber: Int
    ) -> String {
        var prefix = ""
        if includeFilePrefix {
            prefix += "\(displayPath):"
        }
        if includeLineNumber {
            prefix += "\(lineNumber):"
        }
        return prefix
    }

    private static func collectGrepTargets(
        paths: [String],
        recursive: Bool,
        context: inout CommandContext
    ) async -> (targets: [SearchFileTarget], hadError: Bool) {
        var targets: [SearchFileTarget] = []
        var seen = Set<String>()
        var hadError = false

        for path in paths {
            let resolved = context.resolvePath(path)
            do {
                let info = try await context.filesystem.stat(path: resolved)
                if info.isDirectory {
                    guard recursive else {
                        context.writeStderr("grep: \(path): is a directory\n")
                        hadError = true
                        continue
                    }

                    let entries = try await CommandFS.walk(path: resolved, filesystem: context.filesystem)
                    for entry in entries where entry != resolved {
                        let entryInfo = try await context.filesystem.stat(path: entry)
                        guard !entryInfo.isDirectory else {
                            continue
                        }
                        if seen.insert(entry.string).inserted {
                            targets.append(SearchFileTarget(path: entry, displayPath: entry.string))
                        }
                    }
                } else if seen.insert(resolved.string).inserted {
                    targets.append(SearchFileTarget(path: resolved, displayPath: path))
                }
            } catch {
                context.writeStderr("grep: \(path): \(error)\n")
                hadError = true
            }
        }

        return (targets.sorted { $0.displayPath < $1.displayPath }, hadError)
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

        @Flag(name: .short, help: "Match whole words only")
        var w = false

        @Flag(name: .short, help: "Match whole lines only")
        var x = false

        @Flag(name: .short, help: "Show only paths with matching lines")
        var l = false

        @Flag(name: .short, help: "Show count of matching lines per file")
        var c = false

        @Option(name: .short, help: "Stop searching in each file after NUM matches")
        var m: Int?

        @Option(name: .short, help: "Pattern to search for")
        var e: [String] = []

        @Option(name: .short, help: "Read patterns from file")
        var f: [String] = []

        @Option(name: .short, help: "Show NUM lines of context after each match")
        var A: Int = 0

        @Option(name: .short, help: "Show NUM lines of context before each match")
        var B: Int = 0

        @Option(name: .short, help: "Show NUM lines of context before and after each match")
        var C: Int?

        @Flag(name: .long, help: "Include hidden files and directories")
        var hidden = false

        @Flag(name: .customLong("no-ignore"), help: "Do not respect ignore rules (best-effort)")
        var noIgnore = false

        @Option(name: .short, help: "Only search files matching type")
        var t: [String] = []

        @Option(name: .customShort("T"), help: "Do not search files matching type")
        var T: [String] = []

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
        if let maxCount = options.m, maxCount <= 0 {
            context.writeStderr("rg: -m value must be > 0\n")
            return 2
        }

        let afterContext = options.C ?? options.A
        let beforeContext = options.C ?? options.B

        let patterns: [String]
        let roots: [String]
        if options.files {
            if !options.e.isEmpty || !options.f.isEmpty {
                context.writeStderr("rg: cannot combine --files with -e or -f\n")
                return 2
            }
            patterns = []
            roots = options.values.isEmpty ? ["."] : options.values
        } else {
            var resolvedPatterns = options.e
            let patternFileRead = await readPatternsFromFiles(paths: options.f, commandName: "rg", context: &context)
            if patternFileRead.hadError {
                return 2
            }
            resolvedPatterns.append(contentsOf: patternFileRead.patterns)

            if resolvedPatterns.isEmpty {
                guard let rawPattern = options.values.first else {
                    context.writeStderr("rg: missing pattern\n")
                    return 2
                }
                resolvedPatterns.append(rawPattern)
                roots = options.values.count > 1 ? Array(options.values.dropFirst()) : ["."]
            } else {
                roots = options.values.isEmpty ? ["."] : options.values
            }

            guard !resolvedPatterns.isEmpty else {
                context.writeStderr("rg: missing pattern\n")
                return 2
            }
            patterns = resolvedPatterns
        }

        let includeExtensions = resolvedTypeExtensions(options.t)
        let excludeExtensions = resolvedTypeExtensions(options.T)

        let candidate = await collectCandidateFiles(
            roots: roots,
            includeHidden: options.hidden || options.noIgnore,
            globs: options.globs,
            includeExtensions: includeExtensions,
            excludeExtensions: excludeExtensions,
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

        guard !patterns.isEmpty else {
            return 2
        }

        let ignoreCase = options.i || (options.S && !containsUppercase(in: patterns))
        let matcher: SearchMatcher
        do {
            matcher = try SearchMatcher.make(
                commandName: "rg",
                patterns: patterns,
                fixedStrings: options.F,
                ignoreCase: ignoreCase,
                wordMatch: options.w,
                fullLineMatch: options.x
            )
        } catch let error as SearchMatcherBuildError {
            context.writeStderr("\(error.message)\n")
            return 2
        } catch {
            context.writeStderr("rg: failed to build matcher\n")
            return 2
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
                    maxMatchesPerFile: options.m,
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

    private struct CandidateFile {
        let path: WorkspacePath
        let displayPath: String
    }

    private static func searchFile(
        path: WorkspacePath,
        displayPath: String,
        matcher: SearchMatcher,
        includeLineNumbers: Bool,
        fileNamesOnly: Bool,
        countOnly: Bool,
        beforeContext: Int,
        afterContext: Int,
        maxMatchesPerFile: Int?,
        context: inout CommandContext
    ) async throws -> Bool {
        let data = try await context.filesystem.readFile(path: path)
        let content = CommandIO.decodeString(data)
        let lines = CommandIO.splitLines(content)

        var matchedIndices: [Int] = []
        for (index, line) in lines.enumerated() where matcher.matches(line: line) {
            matchedIndices.append(index)
            if let maxMatchesPerFile, matchedIndices.count >= maxMatchesPerFile {
                break
            }
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
        includeExtensions: Set<String>,
        excludeExtensions: Set<String>,
        context: inout CommandContext
    ) async -> (files: [CandidateFile], hadError: Bool) {
        var result: [CandidateFile] = []
        var seen = Set<String>()
        var hadError = false

        let globRegexes: [NSRegularExpression] = globs.compactMap { glob in
            try? NSRegularExpression(pattern: WorkspacePath.globToRegex(glob))
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
                        guard includeHidden || !isHidden(path: entry.string) else {
                            continue
                        }
                        guard matchesType(
                            path: entry.string,
                            includeExtensions: includeExtensions,
                            excludeExtensions: excludeExtensions
                        ) else {
                            continue
                        }
                        guard matchesGlobs(path: entry.string, globs: globRegexes) else {
                            continue
                        }
                        if seen.insert(entry.string).inserted {
                            result.append(CandidateFile(path: entry, displayPath: entry.string))
                        }
                    }
                } else {
                    guard includeHidden || !isHidden(path: resolved.string) else {
                        continue
                    }
                    guard matchesType(
                        path: resolved.string,
                        includeExtensions: includeExtensions,
                        excludeExtensions: excludeExtensions
                    ) else {
                        continue
                    }
                    guard matchesGlobs(path: resolved.string, globs: globRegexes) else {
                        continue
                    }
                    if seen.insert(resolved.string).inserted {
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
        WorkspacePath.splitComponents(path).contains { $0.hasPrefix(".") }
    }

    private static func matchesType(path: String, includeExtensions: Set<String>, excludeExtensions: Set<String>) -> Bool {
        let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
        if !includeExtensions.isEmpty {
            guard !extensionName.isEmpty, includeExtensions.contains(extensionName) else {
                return false
            }
        }
        if !excludeExtensions.isEmpty, !extensionName.isEmpty, excludeExtensions.contains(extensionName) {
            return false
        }
        return true
    }
}

private struct SearchFileTarget {
    let path: WorkspacePath
    let displayPath: String
}

private struct PatternReadResult {
    let patterns: [String]
    let hadError: Bool
}

private enum SearchMatcher {
    case regex([NSRegularExpression])
    case fixedString(patterns: [String], ignoreCase: Bool, wordMatch: Bool, fullLineMatch: Bool)

    static func make(
        commandName: String,
        patterns: [String],
        fixedStrings: Bool,
        ignoreCase: Bool,
        wordMatch: Bool,
        fullLineMatch: Bool
    ) throws -> SearchMatcher {
        if fixedStrings {
            return .fixedString(
                patterns: patterns,
                ignoreCase: ignoreCase,
                wordMatch: wordMatch,
                fullLineMatch: fullLineMatch
            )
        }

        let regexOptions: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        var regexes: [NSRegularExpression] = []
        for pattern in patterns {
            var wrapped = pattern
            if fullLineMatch {
                wrapped = "^(?:\(wrapped))$"
            } else if wordMatch {
                wrapped = "\\b(?:\(wrapped))\\b"
            }
            do {
                regexes.append(try NSRegularExpression(pattern: wrapped, options: regexOptions))
            } catch {
                throw SearchMatcherBuildError(message: "\(commandName): invalid regex: \(pattern)")
            }
        }

        return .regex(regexes)
    }

    func matches(line: String) -> Bool {
        !matchRanges(in: line).isEmpty
    }

    func matchRanges(in line: String) -> [Range<String.Index>] {
        switch self {
        case .regex(let regexes):
            var ranges: [Range<String.Index>] = []
            let searchRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for regex in regexes {
                let matches = regex.matches(in: line, range: searchRange)
                for match in matches {
                    guard let range = Range(match.range, in: line) else {
                        continue
                    }
                    ranges.append(range)
                }
            }
            return Self.deduplicatedSortedRanges(ranges, in: line)

        case let .fixedString(patterns, ignoreCase, wordMatch, fullLineMatch):
            var ranges: [Range<String.Index>] = []
            for pattern in patterns {
                if fullLineMatch {
                    if Self.equals(lhs: line, rhs: pattern, ignoreCase: ignoreCase) {
                        ranges.append(line.startIndex..<line.endIndex)
                    }
                    continue
                }

                var found = Self.fixedRanges(in: line, pattern: pattern, ignoreCase: ignoreCase)
                if wordMatch {
                    found = found.filter { Self.isWholeWord(range: $0, in: line) }
                }
                ranges.append(contentsOf: found)
            }
            return Self.deduplicatedSortedRanges(ranges, in: line)
        }
    }

    private static func equals(lhs: String, rhs: String, ignoreCase: Bool) -> Bool {
        if ignoreCase {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }
        return lhs == rhs
    }

    private static func fixedRanges(in line: String, pattern: String, ignoreCase: Bool) -> [Range<String.Index>] {
        if pattern.isEmpty {
            return [line.startIndex..<line.startIndex]
        }

        var ranges: [Range<String.Index>] = []
        var searchStart = line.startIndex
        let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
        while searchStart < line.endIndex,
              let range = line.range(of: pattern, options: options, range: searchStart..<line.endIndex) {
            ranges.append(range)
            if range.isEmpty {
                searchStart = line.index(after: searchStart)
            } else {
                searchStart = range.upperBound
            }
        }
        return ranges
    }

    private static func deduplicatedSortedRanges(
        _ ranges: [Range<String.Index>],
        in line: String
    ) -> [Range<String.Index>] {
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.lowerBound != rhs.lowerBound {
                return lhs.lowerBound < rhs.lowerBound
            }
            return lhs.upperBound < rhs.upperBound
        }

        var seen = Set<String>()
        var output: [Range<String.Index>] = []
        for range in sorted {
            let nsRange = NSRange(range, in: line)
            let key = "\(nsRange.location):\(nsRange.length)"
            if seen.insert(key).inserted {
                output.append(range)
            }
        }
        return output
    }

    private static func isWholeWord(range: Range<String.Index>, in line: String) -> Bool {
        let beforeIsWord: Bool
        if range.lowerBound == line.startIndex {
            beforeIsWord = false
        } else {
            beforeIsWord = isWordCharacter(line[line.index(before: range.lowerBound)])
        }

        let afterIsWord: Bool
        if range.upperBound == line.endIndex {
            afterIsWord = false
        } else {
            afterIsWord = isWordCharacter(line[range.upperBound])
        }

        return !beforeIsWord && !afterIsWord
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        if character == "_" {
            return true
        }
        return character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

private struct SearchMatcherBuildError: Error {
    let message: String
}

private func readPatternsFromFiles(
    paths: [String],
    commandName: String,
    context: inout CommandContext
) async -> PatternReadResult {
    guard !paths.isEmpty else {
        return PatternReadResult(patterns: [], hadError: false)
    }

    var patterns: [String] = []
    var hadError = false
    for path in paths {
        do {
            let data = try await context.filesystem.readFile(path: context.resolvePath(path))
            let lines = CommandIO.splitLines(CommandIO.decodeString(data))
            patterns.append(contentsOf: lines)
        } catch {
            context.writeStderr("\(commandName): \(path): \(error)\n")
            hadError = true
        }
    }
    return PatternReadResult(patterns: patterns, hadError: hadError)
}

private func containsUppercase(in values: [String]) -> Bool {
    values.contains { value in
        value.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }
}

private func resolvedTypeExtensions(_ types: [String]) -> Set<String> {
    let aliases: [String: Set<String>] = [
        "swift": ["swift"],
        "js": ["js", "mjs", "cjs"],
        "ts": ["ts", "tsx"],
        "json": ["json"],
        "yaml": ["yaml", "yml"],
        "toml": ["toml"],
        "xml": ["xml"],
        "csv": ["csv"],
        "md": ["md", "markdown"],
        "txt": ["txt", "text"],
        "py": ["py"],
        "sh": ["sh", "bash", "zsh"],
        "html": ["html", "htm"],
        "css": ["css"],
        "sql": ["sql"],
        "go": ["go"],
        "rs": ["rs"],
        "java": ["java"],
        "kotlin": ["kt", "kts"],
        "c": ["c", "h"],
        "cpp": ["cpp", "cc", "cxx", "hpp", "hh", "hxx"],
    ]

    var resolved = Set<String>()
    for rawType in types {
        let normalized = rawType.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else {
            continue
        }
        if let mapped = aliases[normalized] {
            resolved.formUnion(mapped)
        } else {
            resolved.insert(normalized)
        }
    }
    return resolved
}
