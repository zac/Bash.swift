import ArgumentParser
import Foundation

struct BasenameCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.short, .long], help: "Support multiple arguments")
        var a = false

        @Option(name: [.short, .customLong("suffix")], help: "Remove a trailing suffix")
        var s: String?

        @Argument(help: "Names (and optional suffix in single-name mode)")
        var values: [String] = []
    }

    static let name = "basename"
    static let overview = "Strip directory and suffix from filenames"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.values.isEmpty else {
            context.writeStderr("basename: missing operand\n")
            return 1
        }

        let suffix: String?
        let names: [String]
        if options.a || options.s != nil {
            suffix = options.s
            names = options.values
        } else if options.values.count >= 2 {
            suffix = options.values.last
            names = Array(options.values.dropLast())
        } else {
            suffix = nil
            names = options.values
        }

        for name in names {
            var base = PathUtils.basename(name)
            if let suffix, !suffix.isEmpty, base.hasSuffix(suffix) {
                base.removeLast(suffix.count)
            }
            context.writeStdout(base + "\n")
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
        @Argument(parsing: .captureForPassthrough, help: "Paths and expression")
        var values: [String] = []
    }

    static let name = "find"
    static let overview = "Search for files in a directory hierarchy"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.values == ["--help"] || options.values == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Search for files in a directory hierarchy
                
                USAGE: find [path...] [expression]
                
                OPTIONS:
                  -name <pattern>      Match basename with wildcard pattern
                  -iname <pattern>     Case-insensitive basename match
                  -path <pattern>      Match full path with wildcard pattern
                  -ipath <pattern>     Case-insensitive path match
                  -regex <pattern>     Match full path with regular expression
                  -iregex <pattern>    Case-insensitive regular expression path match
                  -type <f|d|l>        Filter by file type
                  -mtime <n>           Match file age in days (supports +n, -n)
                  -size <n[ckMGb]>     Match file size with optional unit
                  -perm <mode>         Match permissions (supports MODE, -MODE, /MODE)
                  -maxdepth <n>        Descend at most n levels
                  -mindepth <n>        Do not apply tests at levels less than n
                  -not, !              Negate following expression
                  -a, -and             Logical AND (default between adjacent tests)
                  -o, -or              Logical OR
                  ( ... )              Group expressions
                  -prune               Do not descend into matching directories
                  -print               Print matching path
                  -print0              Print matching path followed by NUL
                  -printf <format>     Print using format directives (%p %P %f %h %s %d %m %%)
                  -delete              Delete matching entries
                  -exec CMD {} ;       Run command per match
                  -exec CMD {} +       Run command once with all matches
                
                """
            )
            return 0
        }

        let parsedResult = parseInvocation(options.values)
        let parsed: ParsedFindInvocation
        switch parsedResult {
        case let .failure(error):
            context.writeStderr(error)
            return 1
        case let .success(value):
            parsed = value
        }

        var runtime = FindRuntime()
        for rootInput in parsed.roots {
            let root = context.resolvePath(rootInput)
            guard await context.filesystem.exists(path: root) else {
                context.writeStderr("find: \(rootInput): No such file or directory\n")
                runtime.hadError = true
                continue
            }

            await traverse(
                path: root,
                rootPath: root,
                depth: 0,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
        }

        await flushBatchExecs(parsed: parsed, context: &context, runtime: &runtime)
        await flushPendingDirectoryDeletes(context: &context, runtime: &runtime)
        return runtime.hadError ? 1 : 0
    }

    private struct ParsedFindInvocation {
        var roots: [String]
        var expression: FindExpression?
        var maxDepth: Int?
        var minDepth: Int?
        var useDefaultPrint: Bool
        var execActions: [ExecAction]
    }

    private struct ExecAction {
        var command: [String]
        var batchMode: Bool
    }

    private indirect enum FindExpression {
        case predicate(FindPredicate)
        case not(FindExpression)
        case and(FindExpression, FindExpression)
        case or(FindExpression, FindExpression)
    }

    private enum FindPredicate {
        case name(pattern: String, ignoreCase: Bool)
        case path(pattern: String, ignoreCase: Bool)
        case regex(pattern: String, ignoreCase: Bool)
        case type(String)
        case mtime(days: Int, comparison: NumericComparison)
        case size(value: Int, unit: SizeUnit, comparison: NumericComparison)
        case perm(mode: Int, matchType: PermissionMatchType)
        case prune
        case print
        case print0
        case printf(format: String)
        case delete
        case exec(actionIndex: Int)
    }

    private enum NumericComparison {
        case exact
        case more
        case less
    }

    private enum SizeUnit {
        case bytes
        case kilobytes
        case megabytes
        case gigabytes
        case blocks
    }

    private enum PermissionMatchType {
        case exact
        case all
        case any
    }

    private enum FindToken {
        case predicate(FindPredicate)
        case and
        case or
        case not
        case lparen
        case rparen
    }

    private struct FindEvalResult {
        var matches: Bool
        var shouldPrune: Bool
    }

    private struct FindRuntime {
        var pendingBatchExecPaths: [Int: [String]] = [:]
        var pendingDirectoryDeletes: Set<String> = []
        var hadError = false
    }

    private enum ParseOutcome<Value> {
        case success(Value)
        case failure(String)
    }

    private static func parseInvocation(_ args: [String]) -> ParseOutcome<ParsedFindInvocation> {
        let (roots, expressionArgs) = splitRootsAndExpressionArgs(args)

        var tokens: [FindToken] = []
        var execActions: [ExecAction] = []
        var maxDepth: Int?
        var minDepth: Int?

        var index = 0
        while index < expressionArgs.count {
            let arg = expressionArgs[index]

            switch arg {
            case "-name", "--name":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.name(pattern: expressionArgs[index + 1], ignoreCase: false)))
                index += 2
            case "-iname":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.name(pattern: expressionArgs[index + 1], ignoreCase: true)))
                index += 2
            case "-path", "--path":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.path(pattern: expressionArgs[index + 1], ignoreCase: false)))
                index += 2
            case "-ipath":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.path(pattern: expressionArgs[index + 1], ignoreCase: true)))
                index += 2
            case "-regex":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.regex(pattern: expressionArgs[index + 1], ignoreCase: false)))
                index += 2
            case "-iregex":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.regex(pattern: expressionArgs[index + 1], ignoreCase: true)))
                index += 2
            case "-type", "--type":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                let type = expressionArgs[index + 1]
                guard ["f", "d", "l"].contains(type) else {
                    return .failure("find: unknown argument to -type: \(type)\n")
                }
                tokens.append(.predicate(.type(type)))
                index += 2
            case "-mtime":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                let parse = parseNumericComparisonToken(expressionArgs[index + 1])
                guard let days = Int(parse.value), days >= 0 else {
                    return .failure("find: invalid argument to -mtime: \(expressionArgs[index + 1])\n")
                }
                tokens.append(.predicate(.mtime(days: days, comparison: parse.comparison)))
                index += 2
            case "-size":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                let token = expressionArgs[index + 1]
                guard let size = parseSizeToken(token) else {
                    return .failure("find: invalid argument to -size: \(token)\n")
                }
                tokens.append(
                    .predicate(
                        .size(
                            value: size.value,
                            unit: size.unit,
                            comparison: size.comparison
                        )
                    )
                )
                index += 2
            case "-perm":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                let token = expressionArgs[index + 1]
                guard let permissions = parsePermissionToken(token) else {
                    return .failure("find: invalid argument to -perm: \(token)\n")
                }
                tokens.append(
                    .predicate(
                        .perm(
                            mode: permissions.mode,
                            matchType: permissions.matchType
                        )
                    )
                )
                index += 2
            case "-maxdepth", "--maxdepth":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                guard let depth = Int(expressionArgs[index + 1]), depth >= 0 else {
                    return .failure("find: maxdepth must be >= 0\n")
                }
                maxDepth = depth
                index += 2
            case "-mindepth", "--mindepth":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                guard let depth = Int(expressionArgs[index + 1]), depth >= 0 else {
                    return .failure("find: mindepth must be >= 0\n")
                }
                minDepth = depth
                index += 2
            case "-a", "-and":
                tokens.append(.and)
                index += 1
            case "-o", "-or":
                tokens.append(.or)
                index += 1
            case "-not", "--not", "!":
                tokens.append(.not)
                index += 1
            case "(", "\\(":
                tokens.append(.lparen)
                index += 1
            case ")", "\\)":
                tokens.append(.rparen)
                index += 1
            case "-prune":
                tokens.append(.predicate(.prune))
                index += 1
            case "-print":
                tokens.append(.predicate(.print))
                index += 1
            case "-print0":
                tokens.append(.predicate(.print0))
                index += 1
            case "-printf":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '\(arg)'\n")
                }
                tokens.append(.predicate(.printf(format: expressionArgs[index + 1])))
                index += 2
            case "-delete":
                tokens.append(.predicate(.delete))
                index += 1
            case "-exec":
                guard index + 1 < expressionArgs.count else {
                    return .failure("find: missing argument to '-exec'\n")
                }
                index += 1

                var command: [String] = []
                var terminator: String?
                while index < expressionArgs.count {
                    let token = expressionArgs[index]
                    if token == ";" || token == "\\;" || token == "+" {
                        terminator = token
                        break
                    }
                    command.append(token)
                    index += 1
                }

                guard let terminator else {
                    return .failure("find: missing argument to `-exec'\n")
                }
                guard !command.isEmpty else {
                    return .failure("find: missing command for -exec\n")
                }

                let actionIndex = execActions.count
                execActions.append(ExecAction(command: command, batchMode: terminator == "+"))
                tokens.append(.predicate(.exec(actionIndex: actionIndex)))
                index += 1
            default:
                if arg.hasPrefix("-") {
                    return .failure("find: unknown predicate '\(arg)'\n")
                }

                // Some users place path operands after -maxdepth/-mindepth before tests.
                // Ignore those only while no expression token exists yet.
                if tokens.isEmpty {
                    index += 1
                } else {
                    return .failure("find: paths must precede expression: \(arg)\n")
                }
            }
        }

        let expressionResult = parseExpression(tokens: tokens)
        let expression: FindExpression?
        switch expressionResult {
        case let .failure(error):
            return .failure(error)
        case let .success(value):
            expression = value
        }

        let useDefaultPrint = !containsExplicitOutput(expression)
        return .success(
            ParsedFindInvocation(
                roots: roots,
                expression: expression,
                maxDepth: maxDepth,
                minDepth: minDepth,
                useDefaultPrint: useDefaultPrint,
                execActions: execActions
            )
        )
    }

    private static func splitRootsAndExpressionArgs(_ args: [String]) -> (roots: [String], expressionArgs: [String]) {
        var roots: [String] = []
        var expressionStart = 0

        while expressionStart < args.count {
            let arg = args[expressionStart]
            if isExpressionStartToken(arg) {
                break
            }
            roots.append(arg)
            expressionStart += 1
        }

        if roots.isEmpty {
            roots = ["."]
        }

        return (roots, Array(args.dropFirst(expressionStart)))
    }

    private static func isExpressionStartToken(_ token: String) -> Bool {
        if token == "!" || token == "(" || token == ")" || token == "\\(" || token == "\\)" {
            return true
        }
        return token.hasPrefix("-")
    }

    private static func parseExpression(tokens: [FindToken]) -> ParseOutcome<FindExpression?> {
        guard !tokens.isEmpty else {
            return .success(nil)
        }

        var index = 0
        var error: String?

        func parsePrimary() -> FindExpression? {
            guard index < tokens.count else {
                error = "find: unexpected end of expression\n"
                return nil
            }

            let token = tokens[index]
            switch token {
            case let .predicate(predicate):
                index += 1
                return .predicate(predicate)
            case .lparen:
                index += 1
                guard let nested = parseOr() else {
                    return nil
                }
                guard index < tokens.count else {
                    error = "find: missing ')'\n"
                    return nil
                }
                guard case .rparen = tokens[index] else {
                    error = "find: missing ')'\n"
                    return nil
                }
                index += 1
                return nested
            case .rparen:
                error = "find: unexpected ')'\n"
                return nil
            case .and:
                error = "find: unexpected operator '-a'\n"
                return nil
            case .or:
                error = "find: unexpected operator '-o'\n"
                return nil
            case .not:
                error = "find: unexpected operator '!'\n"
                return nil
            }
        }

        func parseNot() -> FindExpression? {
            guard index < tokens.count else {
                return nil
            }

            if case .not = tokens[index] {
                index += 1
                guard let inner = parseNot() else {
                    if error == nil {
                        error = "find: missing expression after '!'\n"
                    }
                    return nil
                }
                return .not(inner)
            }

            return parsePrimary()
        }

        func tokenStartsImplicitAnd(_ token: FindToken) -> Bool {
            switch token {
            case .predicate, .not, .lparen:
                return true
            case .and, .or, .rparen:
                return false
            }
        }

        func parseAnd() -> FindExpression? {
            guard var left = parseNot() else {
                return nil
            }

            while index < tokens.count {
                let token = tokens[index]
                switch token {
                case .and:
                    index += 1
                    guard let right = parseNot() else {
                        if error == nil {
                            error = "find: missing expression after '-a'\n"
                        }
                        return nil
                    }
                    left = .and(left, right)
                case .predicate, .not, .lparen:
                    guard let right = parseNot() else {
                        return nil
                    }
                    left = .and(left, right)
                case .or, .rparen:
                    return left
                }
            }

            return left
        }

        func parseOr() -> FindExpression? {
            guard var left = parseAnd() else {
                return nil
            }

            while index < tokens.count {
                let token = tokens[index]
                guard case .or = token else {
                    break
                }

                index += 1
                guard let right = parseAnd() else {
                    if error == nil {
                        error = "find: missing expression after '-o'\n"
                    }
                    return nil
                }
                left = .or(left, right)
            }

            return left
        }

        guard let expression = parseOr() else {
            return .failure(error ?? "find: invalid expression\n")
        }

        if let error {
            return .failure(error)
        }

        if index < tokens.count {
            if case .rparen = tokens[index] {
                return .failure("find: unexpected ')'\n")
            }
            return .failure("find: invalid trailing expression\n")
        }

        return .success(expression)
    }

    private static func containsExplicitOutput(_ expression: FindExpression?) -> Bool {
        guard let expression else {
            return false
        }

        switch expression {
        case let .predicate(predicate):
            switch predicate {
            case .print, .print0, .printf, .exec, .delete:
                return true
            case .name, .path, .regex, .type, .mtime, .size, .perm, .prune:
                return false
            }
        case let .not(inner):
            return containsExplicitOutput(inner)
        case let .and(lhs, rhs), let .or(lhs, rhs):
            return containsExplicitOutput(lhs) || containsExplicitOutput(rhs)
        }
    }

    private static func traverse(
        path: String,
        rootPath: String,
        depth: Int,
        parsed: ParsedFindInvocation,
        context: inout CommandContext,
        runtime: inout FindRuntime
    ) async {
        let info: FileInfo
        do {
            info = try await context.filesystem.stat(path: path)
        } catch {
            context.writeStderr("find: \(path): \(error)\n")
            runtime.hadError = true
            return
        }

        var shouldPrune = false
        if parsed.minDepth == nil || depth >= parsed.minDepth! {
            let evalResult: FindEvalResult
            if let expression = parsed.expression {
                evalResult = await evaluate(
                    expression,
                    path: path,
                    rootPath: rootPath,
                    info: info,
                    depth: depth,
                    parsed: parsed,
                    context: &context,
                    runtime: &runtime
                )
            } else {
                evalResult = FindEvalResult(matches: true, shouldPrune: false)
            }

            shouldPrune = evalResult.shouldPrune
            if evalResult.matches, parsed.useDefaultPrint {
                context.writeStdout("\(path)\n")
            }
        }

        guard info.isDirectory else {
            return
        }

        if let maxDepth = parsed.maxDepth, depth >= maxDepth {
            return
        }
        if shouldPrune {
            return
        }

        let children: [DirectoryEntry]
        do {
            children = try await context.filesystem.listDirectory(path: path)
        } catch {
            context.writeStderr("find: \(path): \(error)\n")
            runtime.hadError = true
            return
        }

        for child in children.sorted(by: { $0.name < $1.name }) {
            await traverse(
                path: PathUtils.join(path, child.name),
                rootPath: rootPath,
                depth: depth + 1,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
        }
    }

    private static func evaluate(
        _ expression: FindExpression,
        path: String,
        rootPath: String,
        info: FileInfo,
        depth: Int,
        parsed: ParsedFindInvocation,
        context: inout CommandContext,
        runtime: inout FindRuntime
    ) async -> FindEvalResult {
        switch expression {
        case let .predicate(predicate):
            return await evaluatePredicate(
                predicate,
                path: path,
                rootPath: rootPath,
                info: info,
                depth: depth,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
        case let .not(inner):
            let result = await evaluate(
                inner,
                path: path,
                rootPath: rootPath,
                info: info,
                depth: depth,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
            return FindEvalResult(matches: !result.matches, shouldPrune: result.shouldPrune)
        case let .and(lhs, rhs):
            let leftResult = await evaluate(
                lhs,
                path: path,
                rootPath: rootPath,
                info: info,
                depth: depth,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
            guard leftResult.matches else {
                return FindEvalResult(matches: false, shouldPrune: leftResult.shouldPrune)
            }

            let rightResult = await evaluate(
                rhs,
                path: path,
                rootPath: rootPath,
                info: info,
                depth: depth,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
            return FindEvalResult(
                matches: rightResult.matches,
                shouldPrune: leftResult.shouldPrune || rightResult.shouldPrune
            )
        case let .or(lhs, rhs):
            let leftResult = await evaluate(
                lhs,
                path: path,
                rootPath: rootPath,
                info: info,
                depth: depth,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
            if leftResult.matches {
                return leftResult
            }

            let rightResult = await evaluate(
                rhs,
                path: path,
                rootPath: rootPath,
                info: info,
                depth: depth,
                parsed: parsed,
                context: &context,
                runtime: &runtime
            )
            return FindEvalResult(
                matches: rightResult.matches,
                shouldPrune: leftResult.shouldPrune || rightResult.shouldPrune
            )
        }
    }

    private static func evaluatePredicate(
        _ predicate: FindPredicate,
        path: String,
        rootPath: String,
        info: FileInfo,
        depth: Int,
        parsed: ParsedFindInvocation,
        context: inout CommandContext,
        runtime: inout FindRuntime
    ) async -> FindEvalResult {
        switch predicate {
        case let .name(pattern, ignoreCase):
            let base = PathUtils.basename(path)
            return FindEvalResult(
                matches: wildcardMatches(pattern: pattern, value: base, ignoreCase: ignoreCase),
                shouldPrune: false
            )
        case let .path(pattern, ignoreCase):
            return FindEvalResult(
                matches: wildcardMatches(pattern: pattern, value: path, ignoreCase: ignoreCase),
                shouldPrune: false
            )
        case let .regex(pattern, ignoreCase):
            return FindEvalResult(
                matches: regexMatches(pattern: pattern, value: path, ignoreCase: ignoreCase),
                shouldPrune: false
            )
        case let .type(type):
            switch type {
            case "f":
                return FindEvalResult(matches: !info.isDirectory && !info.isSymbolicLink, shouldPrune: false)
            case "d":
                return FindEvalResult(matches: info.isDirectory, shouldPrune: false)
            case "l":
                return FindEvalResult(matches: info.isSymbolicLink, shouldPrune: false)
            default:
                return FindEvalResult(matches: false, shouldPrune: false)
            }
        case let .mtime(days, comparison):
            guard let modified = info.modificationDate else {
                return FindEvalResult(matches: false, shouldPrune: false)
            }
            let ageDays = Date().timeIntervalSince(modified) / (60 * 60 * 24)
            let matches: Bool
            switch comparison {
            case .exact:
                matches = Int(floor(ageDays)) == days
            case .more:
                matches = ageDays > Double(days)
            case .less:
                matches = ageDays < Double(days)
            }
            return FindEvalResult(matches: matches, shouldPrune: false)
        case let .size(value, unit, comparison):
            let targetBytes: UInt64
            switch unit {
            case .bytes:
                targetBytes = UInt64(value)
            case .kilobytes:
                targetBytes = UInt64(value) * 1_024
            case .megabytes:
                targetBytes = UInt64(value) * 1_024 * 1_024
            case .gigabytes:
                targetBytes = UInt64(value) * 1_024 * 1_024 * 1_024
            case .blocks:
                targetBytes = UInt64(value) * 512
            }

            let matches: Bool
            switch comparison {
            case .exact:
                if case .blocks = unit {
                    let blockCount = max(UInt64(1), (info.size + 511) / 512)
                    matches = blockCount == UInt64(value)
                } else {
                    matches = info.size == targetBytes
                }
            case .more:
                matches = info.size > targetBytes
            case .less:
                matches = info.size < targetBytes
            }
            return FindEvalResult(matches: matches, shouldPrune: false)
        case let .perm(mode, matchType):
            let current = info.permissions & 0o777
            let target = mode & 0o777
            let matches: Bool
            switch matchType {
            case .exact:
                matches = current == target
            case .all:
                matches = (current & target) == target
            case .any:
                matches = (current & target) != 0
            }
            return FindEvalResult(matches: matches, shouldPrune: false)
        case .prune:
            return FindEvalResult(matches: true, shouldPrune: true)
        case .print:
            context.writeStdout("\(path)\n")
            return FindEvalResult(matches: true, shouldPrune: false)
        case .print0:
            context.stdout.append(Data(path.utf8))
            context.stdout.append(Data([0]))
            return FindEvalResult(matches: true, shouldPrune: false)
        case let .printf(format):
            context.writeStdout(renderPrintf(format: format, path: path, rootPath: rootPath, info: info, depth: depth))
            return FindEvalResult(matches: true, shouldPrune: false)
        case .delete:
            if info.isDirectory {
                runtime.pendingDirectoryDeletes.insert(path)
                return FindEvalResult(matches: true, shouldPrune: false)
            }

            do {
                try await context.filesystem.remove(path: path, recursive: false)
                return FindEvalResult(matches: true, shouldPrune: false)
            } catch {
                context.writeStderr("find: cannot delete '\(path)': \(error)\n")
                runtime.hadError = true
                return FindEvalResult(matches: false, shouldPrune: false)
            }
        case let .exec(actionIndex):
            guard actionIndex < parsed.execActions.count else {
                runtime.hadError = true
                context.writeStderr("find: invalid -exec action\n")
                return FindEvalResult(matches: false, shouldPrune: false)
            }

            let action = parsed.execActions[actionIndex]
            if action.batchMode {
                runtime.pendingBatchExecPaths[actionIndex, default: []].append(path)
                return FindEvalResult(matches: true, shouldPrune: false)
            }

            let argv = expandExecCommandSingle(action.command, path: path)
            let subcommand = await context.runSubcommandIsolated(argv, stdin: Data())
            context.stdout.append(subcommand.result.stdout)
            context.stderr.append(subcommand.result.stderr)
            if subcommand.result.exitCode != 0 {
                runtime.hadError = true
            }
            return FindEvalResult(matches: subcommand.result.exitCode == 0, shouldPrune: false)
        }
    }

    private static func flushPendingDirectoryDeletes(
        context: inout CommandContext,
        runtime: inout FindRuntime
    ) async {
        let ordered = runtime.pendingDirectoryDeletes.sorted {
            PathUtils.splitComponents($0).count > PathUtils.splitComponents($1).count
        }

        for path in ordered {
            guard await context.filesystem.exists(path: path) else {
                continue
            }

            do {
                try await context.filesystem.remove(path: path, recursive: false)
            } catch {
                context.writeStderr("find: cannot delete '\(path)': \(error)\n")
                runtime.hadError = true
            }
        }
    }

    private static func flushBatchExecs(
        parsed: ParsedFindInvocation,
        context: inout CommandContext,
        runtime: inout FindRuntime
    ) async {
        for actionIndex in runtime.pendingBatchExecPaths.keys.sorted() {
            guard actionIndex < parsed.execActions.count else {
                runtime.hadError = true
                continue
            }
            let paths = runtime.pendingBatchExecPaths[actionIndex] ?? []
            guard !paths.isEmpty else {
                continue
            }

            let action = parsed.execActions[actionIndex]
            let argv = expandExecCommandBatch(action.command, paths: paths)
            let subcommand = await context.runSubcommandIsolated(argv, stdin: Data())
            context.stdout.append(subcommand.result.stdout)
            context.stderr.append(subcommand.result.stderr)
            if subcommand.result.exitCode != 0 {
                runtime.hadError = true
            }
        }
    }

    private static func expandExecCommandSingle(_ command: [String], path: String) -> [String] {
        command.map { token in
            token.replacingOccurrences(of: "{}", with: path)
        }
    }

    private static func expandExecCommandBatch(_ command: [String], paths: [String]) -> [String] {
        var expanded: [String] = []
        var replacedAnyPlaceholder = false

        for token in command {
            if token == "{}" {
                replacedAnyPlaceholder = true
                expanded.append(contentsOf: paths)
                continue
            }

            if token.contains("{}") {
                replacedAnyPlaceholder = true
                for path in paths {
                    expanded.append(token.replacingOccurrences(of: "{}", with: path))
                }
                continue
            }

            expanded.append(token)
        }

        if !replacedAnyPlaceholder {
            expanded.append(contentsOf: paths)
        }

        return expanded
    }

    private static func wildcardMatches(pattern: String, value: String, ignoreCase: Bool) -> Bool {
        if ignoreCase {
            return CommandFS.wildcardMatch(
                pattern: pattern.lowercased(),
                value: value.lowercased()
            )
        }

        return CommandFS.wildcardMatch(pattern: pattern, value: value)
    }

    private static func regexMatches(pattern: String, value: String, ignoreCase: Bool) -> Bool {
        let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static func parseNumericComparisonToken(_ token: String) -> (comparison: NumericComparison, value: String) {
        if let first = token.first {
            if first == "+" {
                return (.more, String(token.dropFirst()))
            }
            if first == "-" {
                return (.less, String(token.dropFirst()))
            }
        }
        return (.exact, token)
    }

    private static func parseSizeToken(_ token: String) -> (value: Int, unit: SizeUnit, comparison: NumericComparison)? {
        let parsed = parseNumericComparisonToken(token)
        guard !parsed.value.isEmpty else {
            return nil
        }

        let rawValue = parsed.value
        let last = rawValue.last ?? " "

        let numberToken: String
        let unit: SizeUnit
        switch last {
        case "c":
            numberToken = String(rawValue.dropLast())
            unit = .bytes
        case "k":
            numberToken = String(rawValue.dropLast())
            unit = .kilobytes
        case "M", "m":
            numberToken = String(rawValue.dropLast())
            unit = .megabytes
        case "G", "g":
            numberToken = String(rawValue.dropLast())
            unit = .gigabytes
        case "b":
            numberToken = String(rawValue.dropLast())
            unit = .blocks
        default:
            numberToken = rawValue
            unit = .blocks
        }

        guard let value = Int(numberToken), value >= 0 else {
            return nil
        }
        return (value, unit, parsed.comparison)
    }

    private static func parsePermissionToken(_ token: String) -> (mode: Int, matchType: PermissionMatchType)? {
        guard !token.isEmpty else {
            return nil
        }

        let matchType: PermissionMatchType
        let modeToken: String
        if token.hasPrefix("-") {
            matchType = .all
            modeToken = String(token.dropFirst())
        } else if token.hasPrefix("/") {
            matchType = .any
            modeToken = String(token.dropFirst())
        } else {
            matchType = .exact
            modeToken = token
        }

        guard !modeToken.isEmpty else {
            return nil
        }
        guard modeToken.allSatisfy({ "01234567".contains($0) }) else {
            return nil
        }
        guard let mode = Int(modeToken, radix: 8) else {
            return nil
        }
        return (mode, matchType)
    }

    private static func renderPrintf(
        format: String,
        path: String,
        rootPath: String,
        info: FileInfo,
        depth: Int
    ) -> String {
        let unescaped = unescapePrintf(format)
        let chars = Array(unescaped)
        var output = ""
        var index = 0
        let mode = String(format: "%03o", info.permissions & 0o777)

        while index < chars.count {
            let char = chars[index]
            guard char == "%" else {
                output.append(char)
                index += 1
                continue
            }

            index += 1
            guard index < chars.count else {
                output.append("%")
                break
            }

            let spec = chars[index]
            switch spec {
            case "%":
                output.append("%")
            case "p":
                output += path
            case "P":
                output += relativeToRoot(path: path, rootPath: rootPath)
            case "f":
                output += PathUtils.basename(path)
            case "h":
                output += PathUtils.dirname(path)
            case "s":
                output += String(info.size)
            case "d":
                output += String(depth)
            case "m":
                output += mode
            default:
                output.append("%")
                output.append(spec)
            }
            index += 1
        }

        return output
    }

    private static func relativeToRoot(path: String, rootPath: String) -> String {
        if path == rootPath {
            return "."
        }

        if rootPath == "/" {
            return String(path.drop(while: { $0 == "/" }))
        }

        let prefix = rootPath + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }

        return path
    }

    private static func unescapePrintf(_ input: String) -> String {
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]
            guard char == "\\" else {
                output.append(char)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append("\\")
                break
            }

            switch input[next] {
            case "n":
                output.append("\n")
            case "t":
                output.append("\t")
            case "r":
                output.append("\r")
            case "0":
                output.append("\0")
            case "\\":
                output.append("\\")
            default:
                output.append(input[next])
            }
            index = input.index(after: next)
        }

        return output
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
            return 0
        }

        var hadMissingKey = false
        for key in options.keys {
            if let value = context.environment[key] {
                context.writeStdout("\(value)\n")
            } else {
                hadMissingKey = true
            }
        }
        return hadMissingKey ? 1 : 0
    }
}

struct PwdCommand: BuiltinCommand {
    struct Options: ParsableArguments {}

    private static let hostRootEnvKey = "BASHSWIFT_PWD_HOST_ROOT"

    static let name = "pwd"
    static let overview = "Print current working directory"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let renderedPath: String
        if let hostRoot = context.environment[hostRootEnvKey],
           !hostRoot.isEmpty,
           hostRoot.hasPrefix("/") {
            let normalizedHostRoot: String
            if hostRoot == "/" {
                normalizedHostRoot = "/"
            } else if hostRoot.hasSuffix("/") {
                normalizedHostRoot = String(hostRoot.dropLast())
            } else {
                normalizedHostRoot = hostRoot
            }
            if context.currentDirectory == "/" {
                renderedPath = normalizedHostRoot
            } else if normalizedHostRoot == "/" {
                renderedPath = context.currentDirectory
            } else {
                renderedPath = normalizedHostRoot + context.currentDirectory
            }
        } else {
            renderedPath = context.currentDirectory
        }

        context.writeStdout("\(renderedPath)\n")
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
