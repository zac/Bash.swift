import Foundation
import BashCore

#if canImport(CLibgit2)
import CLibgit2
#elseif canImport(Clibgit2)
import Clibgit2
#endif

struct GitExecutionResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32

    init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

enum GitEngine {
    static func run(arguments: [String], context: inout CommandContext) async -> GitExecutionResult {
        #if canImport(CLibgit2) || canImport(Clibgit2)
        return await runWithLibgit2(arguments: arguments, context: &context)
        #else
        _ = arguments
        _ = context
        return GitExecutionResult(
            stderr: "git: libgit2 is unavailable on this platform/build\n",
            exitCode: 1
        )
        #endif
    }
}

#if canImport(CLibgit2) || canImport(Clibgit2)
private enum GitEngineError: Error {
    case usage(String)
    case runtime(String)
}

private struct CloneSource {
    let sourceURL: String
    let projection: GitRepositoryProjection?
    let virtualPath: WorkspacePath?
}

private struct GitRepositoryProjection {
    let virtualRoot: WorkspacePath
    let temporaryDirectory: URL
    let localRoot: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func syncBack(filesystem: any FileSystem) async throws {
        try await GitFilesystemProjection.syncFromLocal(
            localRoot: localRoot,
            toFilesystemRoot: virtualRoot,
            filesystem: filesystem
        )
    }
}

private enum GitEngineLibgit2 {
    static func run(arguments: [String], context: inout CommandContext) async -> GitExecutionResult {
        guard let subcommand = arguments.first else {
            return GitExecutionResult(
                stderr: usageText(),
                exitCode: 2
            )
        }

        let remaining = Array(arguments.dropFirst())

        do {
            switch subcommand {
            case "--help", "-h", "help":
                return GitExecutionResult(stdout: usageText(), exitCode: 0)

            case "init":
                return try await runInit(arguments: remaining, context: &context)

            case "clone":
                return try await runClone(arguments: remaining, context: &context)

            case "status":
                return try await runStatus(arguments: remaining, context: &context)

            case "diff":
                return try await runDiff(arguments: remaining, context: &context)

            case "show":
                return try await runShow(arguments: remaining, context: &context)

            case "add":
                return try await runAdd(arguments: remaining, context: &context)

            case "branch":
                return try await runBranch(arguments: remaining, context: &context)

            case "remote":
                return try await runRemote(arguments: remaining, context: &context)

            case "commit":
                return try await runCommit(arguments: remaining, context: &context)

            case "config":
                return try await runConfig(arguments: remaining, context: &context)

            case "log":
                return try await runLog(arguments: remaining, context: &context)

            case "rev-parse":
                return try await runRevParse(arguments: remaining, context: &context)

            case "version":
                return try runVersion(arguments: remaining)

            default:
                return GitExecutionResult(
                    stderr: "git: unsupported subcommand '\(subcommand)'\n",
                    exitCode: 2
                )
            }
        } catch let GitEngineError.usage(message) {
            return GitExecutionResult(stderr: message, exitCode: 2)
        } catch let GitEngineError.runtime(message) {
            return GitExecutionResult(stderr: "git: \(message)\n", exitCode: 1)
        } catch {
            return GitExecutionResult(stderr: "git: \(error)\n", exitCode: 1)
        }
    }

    private static func usageText() -> String {
        """
        OVERVIEW: Basic git commands powered by libgit2

        USAGE: git <subcommand> [options]

        SUBCOMMANDS:
          init [path]
          clone <repository> [directory]
          status [--short] [--branch]
          diff [--stat|--name-only]
          show --stat
          add [-A|--all] <paths...>
          branch --show-current
          remote [-v]
          commit -m <message>
          config <user.name|user.email> [value]
          log [--oneline] [-n <count>]
          rev-parse <--is-inside-work-tree|--abbrev-ref HEAD>
          version

        """
    }

    private static func runInit(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        if arguments.count > 1 {
            throw GitEngineError.usage("usage: git init [path]\n")
        }

        let targetPath = context.resolvePath(arguments.first ?? ".")
        if await !context.filesystem.exists(path: targetPath) {
            try await context.filesystem.createDirectory(path: targetPath, recursive: true)
        }

        let projection = try await GitFilesystemProjection.materialize(
            virtualRoot: targetPath,
            filesystem: context.filesystem
        )
        defer { projection.cleanup() }

        try withLibgit2 {
            var repository: OpaquePointer?
            try withCString(path: projection.localRoot.path) { cPath in
                try check(git_repository_init(&repository, cPath, 0), action: "init repository")
            }
            if let repository {
                git_repository_free(repository)
            }
        }

        try await projection.syncBack(filesystem: context.filesystem)
        let normalized = targetPath.isRoot ? "/" : targetPath.string + "/"
        return GitExecutionResult(stdout: "Initialized empty Git repository in \(normalized).git/\n", exitCode: 0)
    }

    private static func runClone(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        let parsed = try parseCloneArguments(arguments)
        let source = try await resolveCloneSource(repository: parsed.repository, context: context)
        defer { source.projection?.cleanup() }

        let destinationArgument = parsed.directory ?? defaultCloneDirectoryName(
            repositoryArgument: parsed.repository,
            localRepositoryPath: source.virtualPath
        )
        let destinationPath = context.resolvePath(destinationArgument)
        let destinationName = basename(of: destinationPath)

        if destinationName.isEmpty || destinationName == "/" || destinationName == "." || destinationName == ".." {
            throw GitEngineError.runtime("invalid destination path '\(destinationArgument)'")
        }
        if await context.filesystem.exists(path: destinationPath) {
            throw GitEngineError.runtime("destination path '\(destinationPath)' already exists")
        }

        let parentPath = parent(of: destinationPath)
        guard await context.filesystem.exists(path: parentPath) else {
            throw GitEngineError.runtime("destination parent '\(parentPath)' does not exist")
        }

        let parentInfo = try await context.filesystem.stat(path: parentPath)
        guard parentInfo.isDirectory else {
            throw GitEngineError.runtime("destination parent '\(parentPath)' is not a directory")
        }

        let projection = try await GitFilesystemProjection.materialize(
            virtualRoot: parentPath,
            filesystem: context.filesystem
        )
        defer { projection.cleanup() }

        let localDestination = projection.localRoot.appendingPathComponent(destinationName, isDirectory: true)

        try withLibgit2 {
            var repository: OpaquePointer?
            try withCString(path: source.sourceURL) { sourcePath in
                try withCString(path: localDestination.path) { destinationPath in
                    try check(git_clone(&repository, sourcePath, destinationPath, nil), action: "clone repository")
                }
            }
            if let repository {
                git_repository_free(repository)
            }
        }

        try await projection.syncBack(filesystem: context.filesystem)
        return GitExecutionResult(stderr: "Cloning into '\(destinationName)'...\n", exitCode: 0)
    }

    private static func runStatus(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        var short = false
        var branch = false
        for argument in arguments {
            switch argument {
            case "--short", "-s":
                short = true
            case "--branch", "-b":
                branch = true
            case "-sb", "-bs":
                short = true
                branch = true
            default:
                throw GitEngineError.usage("usage: git status [--short] [--branch]\n")
            }
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let output = try withLibgit2 {
            try statusOutput(localRoot: projection.localRoot, short: short, branch: branch)
        }

        return GitExecutionResult(stdout: output, exitCode: 0)
    }

    private static func runDiff(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        var stat = false
        var nameOnly = false

        for argument in arguments {
            switch argument {
            case "--stat":
                stat = true
            case "--name-only":
                nameOnly = true
            default:
                throw GitEngineError.usage("usage: git diff [--stat|--name-only]\n")
            }
        }

        if stat == nameOnly {
            throw GitEngineError.usage("usage: git diff [--stat|--name-only]\n")
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let output = try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }

            let diff = try makeWorktreeDiff(repository: repository)
            defer { git_diff_free(diff) }

            if stat {
                return try diffStatOutput(diff: diff)
            }
            return diffNameOnlyOutput(diff: diff)
        }

        return GitExecutionResult(stdout: output, exitCode: 0)
    }

    private static func runShow(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        guard arguments == ["--stat"] else {
            throw GitEngineError.usage("usage: git show --stat\n")
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let output = try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }

            guard let commit = try lookupHeadCommit(repository: repository) else {
                throw GitEngineError.runtime("your current branch does not have any commits yet")
            }
            defer { git_commit_free(commit) }

            return try showStatOutput(repository: repository, commit: commit)
        }

        return GitExecutionResult(stdout: output, exitCode: 0)
    }

    private static func runAdd(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        var all = false
        var paths: [String] = []

        for argument in arguments {
            switch argument {
            case "-A", "--all":
                all = true
            default:
                if argument.hasPrefix("-") {
                    throw GitEngineError.usage("usage: git add [-A|--all] <paths...>\n")
                }
                paths.append(argument)
            }
        }

        if !all && paths.isEmpty {
            throw GitEngineError.usage("usage: git add [-A|--all] <paths...>\n")
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }

            var indexPointer: OpaquePointer?
            try check(git_repository_index(&indexPointer, repository), action: "open repository index")
            guard let indexPointer else {
                throw GitEngineError.runtime("failed to open repository index")
            }
            defer { git_index_free(indexPointer) }

            if all || paths.contains(".") {
                try check(git_index_add_all(indexPointer, nil, 0, nil, nil), action: "stage files")
                try check(git_index_update_all(indexPointer, nil, nil, nil), action: "refresh staged files")
            }

            for argument in paths where argument != "." {
                let resolvedPath = context.resolvePath(argument)
                guard let relativePath = relativePath(of: resolvedPath, fromRoot: projection.virtualRoot) else {
                    throw GitEngineError.runtime("path '\(argument)' is outside repository root")
                }
                let code = try withCString(path: relativePath) { cPath in
                    git_index_add_bypath(indexPointer, cPath)
                }
                if code == GIT_ENOTFOUND.rawValue {
                    _ = try withCString(path: relativePath) { cPath in
                        git_index_remove_bypath(indexPointer, cPath)
                    }
                } else {
                    try check(code, action: "stage '\(relativePath)'")
                }
            }

            try check(git_index_write(indexPointer), action: "write index")
        }

        try await projection.syncBack(filesystem: context.filesystem)
        return GitExecutionResult(exitCode: 0)
    }

    private static func runBranch(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        guard arguments == ["--show-current"] else {
            throw GitEngineError.usage("usage: git branch --show-current\n")
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let output = try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }
            return try branchNameForDisplay(repository: repository).map { "\($0)\n" } ?? ""
        }

        return GitExecutionResult(stdout: output, exitCode: 0)
    }

    private static func runRemote(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        var verbose = false
        for argument in arguments {
            switch argument {
            case "-v", "--verbose":
                verbose = true
            default:
                throw GitEngineError.usage("usage: git remote [-v]\n")
            }
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let output = try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }
            return try remoteOutput(repository: repository, verbose: verbose)
        }

        return GitExecutionResult(stdout: output, exitCode: 0)
    }

    private static func runCommit(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        let message = try parseCommitMessage(arguments)
        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let result = try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }

            var indexPointer: OpaquePointer?
            try check(git_repository_index(&indexPointer, repository), action: "open repository index")
            guard let indexPointer else {
                throw GitEngineError.runtime("failed to open repository index")
            }
            defer { git_index_free(indexPointer) }

            var treeOID = git_oid()
            try check(git_index_write_tree(&treeOID, indexPointer), action: "write tree")

            var treePointer: OpaquePointer?
            try check(git_tree_lookup(&treePointer, repository, &treeOID), action: "read tree")
            guard let treePointer else {
                throw GitEngineError.runtime("failed to read tree")
            }
            defer { git_tree_free(treePointer) }

            let parentCommit = try lookupHeadCommit(repository: repository)
            defer {
                if let parentCommit {
                    git_commit_free(parentCommit)
                }
            }

            if let parentCommit {
                if let parentTreeOID = git_commit_tree_id(parentCommit), git_oid_equal(parentTreeOID, &treeOID) == 1 {
                    return GitExecutionResult(
                        stdout: "nothing to commit, working tree clean\n",
                        exitCode: 1
                    )
                }
            }

            let signature = try createSignature(repository: repository, environment: context.environment)
            defer { git_signature_free(signature) }

            var commitOID = git_oid()
            let subject = firstLine(of: message)
            try withCString(path: message) { messageCString in
                if let parentCommit {
                    var parents: [OpaquePointer?] = [parentCommit]
                    try check(
                        parents.withUnsafeMutableBufferPointer { buffer -> Int32 in
                            git_commit_create(
                                &commitOID,
                                repository,
                                "HEAD",
                                UnsafePointer(signature),
                                UnsafePointer(signature),
                                nil,
                                messageCString,
                                treePointer,
                                1,
                                buffer.baseAddress
                            )
                        },
                        action: "create commit"
                    )
                } else {
                    try check(
                        git_commit_create(
                            &commitOID,
                            repository,
                            "HEAD",
                            UnsafePointer(signature),
                            UnsafePointer(signature),
                            nil,
                            messageCString,
                            treePointer,
                            0,
                            nil
                        ),
                        action: "create commit"
                    )
                }
            }

            let branch = try currentBranchName(repository: repository)
            let shortOID = shortOIDString(commitOID)
            return GitExecutionResult(stdout: "[\(branch) \(shortOID)] \(subject)\n", exitCode: 0)
        }

        if result.exitCode == 0 {
            try await projection.syncBack(filesystem: context.filesystem)
        }
        return result
    }

    private static func runLog(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        var oneline = false
        var limit = 10

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--oneline":
                oneline = true
            case "-n", "--max-count":
                guard index + 1 < arguments.count, let parsed = Int(arguments[index + 1]), parsed > 0 else {
                    throw GitEngineError.usage("usage: git log [--oneline] [-n <count>]\n")
                }
                limit = parsed
                index += 1
            default:
                throw GitEngineError.usage("usage: git log [--oneline] [-n <count>]\n")
            }
            index += 1
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let output = try withLibgit2 {
            try logOutput(localRoot: projection.localRoot, oneline: oneline, limit: limit)
        }

        return GitExecutionResult(stdout: output, exitCode: 0)
    }

    private static func runConfig(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        guard arguments.count == 1 || arguments.count == 2 else {
            throw GitEngineError.usage("usage: git config <user.name|user.email> [value]\n")
        }

        let key = arguments[0]
        guard key == "user.name" || key == "user.email" else {
            throw GitEngineError.usage("usage: git config <user.name|user.email> [value]\n")
        }

        let projection = try await requireRepositoryProjection(context: context)
        defer { projection.cleanup() }

        let result = try withLibgit2 {
            let repository = try openRepository(path: projection.localRoot.path)
            defer { git_repository_free(repository) }

            if arguments.count == 2 {
                try setConfigValue(repository: repository, key: key, value: arguments[1])
                return GitExecutionResult(exitCode: 0)
            }

            guard let value = try configValue(repository: repository, key: key) else {
                return GitExecutionResult(exitCode: 1)
            }
            return GitExecutionResult(stdout: "\(value)\n", exitCode: 0)
        }

        if arguments.count == 2, result.exitCode == 0 {
            try await projection.syncBack(filesystem: context.filesystem)
        }
        return result
    }

    private static func runRevParse(arguments: [String], context: inout CommandContext) async throws -> GitExecutionResult {
        let start = WorkspacePath(normalizing: context.currentDirectory)
        guard let _ = try await GitFilesystemProjection.findRepositoryRoot(
            from: start,
            filesystem: context.filesystem
        ) else {
            return GitExecutionResult(
                stderr: "fatal: not a git repository (or any of the parent directories): .git\n",
                exitCode: 128
            )
        }

        switch arguments {
        case ["--is-inside-work-tree"]:
            return GitExecutionResult(stdout: "true\n", exitCode: 0)

        case ["--abbrev-ref", "HEAD"]:
            let projection = try await requireRepositoryProjection(context: context)
            defer { projection.cleanup() }
            let output = try withLibgit2 {
                let repository = try openRepository(path: projection.localRoot.path)
                defer { git_repository_free(repository) }
                let branch = try branchNameForDisplay(repository: repository) ?? "HEAD"
                return "\(branch)\n"
            }
            return GitExecutionResult(stdout: output, exitCode: 0)

        default:
            throw GitEngineError.usage("usage: git rev-parse <--is-inside-work-tree|--abbrev-ref HEAD>\n")
        }
    }

    private static func runVersion(arguments: [String]) throws -> GitExecutionResult {
        guard arguments.isEmpty else {
            throw GitEngineError.usage("usage: git version\n")
        }

        var major = Int32()
        var minor = Int32()
        var revision = Int32()
        _ = git_libgit2_version(&major, &minor, &revision)
        let features = git_libgit2_features()

        var featureNames: [String] = []
        if (features & Int32(GIT_FEATURE_HTTPS.rawValue)) != 0 {
            featureNames.append("https")
        }
        if (features & Int32(GIT_FEATURE_SSH.rawValue)) != 0 {
            featureNames.append("ssh")
        }
        if (features & Int32(GIT_FEATURE_THREADS.rawValue)) != 0 {
            featureNames.append("threads")
        }

        let featureString = featureNames.isEmpty ? "none" : featureNames.joined(separator: ", ")
        return GitExecutionResult(
            stdout: "git (BashGit/libgit2) \(major).\(minor).\(revision)\nfeatures: \(featureString)\n",
            exitCode: 0
        )
    }

    private static func requireRepositoryProjection(context: CommandContext) async throws -> GitRepositoryProjection {
        let start = WorkspacePath(normalizing: context.currentDirectory)
        guard let repositoryRoot = try await GitFilesystemProjection.findRepositoryRoot(
            from: start,
            filesystem: context.filesystem
        ) else {
            throw GitEngineError.runtime("not a git repository (or any parent directories): .git")
        }

        return try await GitFilesystemProjection.materialize(
            virtualRoot: repositoryRoot,
            filesystem: context.filesystem
        )
    }

    private static func parseCloneArguments(_ arguments: [String]) throws -> (repository: String, directory: String?) {
        var positionals: [String] = []
        var parsingOptions = true

        for argument in arguments {
            if parsingOptions && argument == "--" {
                parsingOptions = false
                continue
            }
            if parsingOptions && argument.hasPrefix("-") {
                throw GitEngineError.usage("usage: git clone <repository> [directory]\n")
            }
            positionals.append(argument)
        }

        guard positionals.count == 1 || positionals.count == 2 else {
            throw GitEngineError.usage("usage: git clone <repository> [directory]\n")
        }
        return (positionals[0], positionals.count == 2 ? positionals[1] : nil)
    }

    private static func resolveCloneSource(repository: String, context: CommandContext) async throws -> CloneSource {
        if isRemoteRepository(repository) {
            let remoteURL = normalizedRemoteRepositoryURL(repository)
            let decision = await context.requestNetworkPermission(
                url: remoteURL,
                method: "CLONE"
            )
            if case let .deny(message) = decision {
                throw GitEngineError.runtime(message ?? "network access denied: CLONE \(remoteURL)")
            }

            return CloneSource(
                sourceURL: repository,
                projection: nil,
                virtualPath: nil
            )
        }

        let resolvedPath = context.resolvePath(repository)
        guard await context.filesystem.exists(path: resolvedPath) else {
            throw GitEngineError.runtime("repository '\(repository)' does not exist")
        }

        let info = try await context.filesystem.stat(path: resolvedPath)
        guard info.isDirectory else {
            throw GitEngineError.runtime("repository '\(repository)' is not a directory")
        }

        let projection = try await GitFilesystemProjection.materialize(
            virtualRoot: resolvedPath,
            filesystem: context.filesystem
        )

        return CloneSource(
            sourceURL: projection.localRoot.path,
            projection: projection,
            virtualPath: resolvedPath
        )
    }

    private static func defaultCloneDirectoryName(
        repositoryArgument: String,
        localRepositoryPath: WorkspacePath?
    ) -> String {
        if let localRepositoryPath {
            var name = basename(of: localRepositoryPath)
            if name.hasSuffix(".git") {
                name.removeLast(4)
            }
            return name.isEmpty ? "repository" : name
        }

        var candidate = repositoryArgument.trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }

        if let slashIndex = candidate.lastIndex(of: "/") {
            candidate = String(candidate[candidate.index(after: slashIndex)...])
        }

        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }

        if let colonIndex = candidate.lastIndex(of: ":"), colonIndex != candidate.startIndex {
            let tail = String(candidate[candidate.index(after: colonIndex)...])
            if !tail.isEmpty {
                candidate = tail
            }
        }

        return candidate.isEmpty ? "repository" : candidate
    }

    private static func isRemoteRepository(_ repository: String) -> Bool {
        if repository.contains("://") {
            return true
        }
        if repository.hasPrefix("git@") {
            return true
        }
        guard let colonIndex = repository.firstIndex(of: ":") else {
            return false
        }
        if let slashIndex = repository.firstIndex(of: "/"), slashIndex < colonIndex {
            return false
        }
        return repository[..<colonIndex].contains("@")
    }

    private static func normalizedRemoteRepositoryURL(_ repository: String) -> String {
        if repository.contains("://") {
            return repository
        }

        if let colonIndex = repository.firstIndex(of: ":"),
           repository[..<colonIndex].contains("@") {
            let authority = String(repository[..<colonIndex])
            let path = String(repository[repository.index(after: colonIndex)...])
            return "ssh://\(authority)/\(path)"
        }

        return repository
    }

    private static func parseCommitMessage(_ arguments: [String]) throws -> String {
        var message: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-m", "--message":
                guard index + 1 < arguments.count else {
                    throw GitEngineError.usage("usage: git commit -m <message>\n")
                }
                message = arguments[index + 1]
                index += 1
            default:
                throw GitEngineError.usage("usage: git commit -m <message>\n")
            }
            index += 1
        }

        guard let message, !message.isEmpty else {
            throw GitEngineError.usage("usage: git commit -m <message>\n")
        }
        return message
    }

    private static func statusOutput(localRoot: URL, short: Bool, branch: Bool) throws -> String {
        let repository = try openRepository(path: localRoot.path)
        defer { git_repository_free(repository) }

        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)), action: "initialize status options")
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = UInt32(GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue)

        var statusList: OpaquePointer?
        try check(git_status_list_new(&statusList, repository, &options), action: "collect status")
        guard let statusList else {
            return ""
        }
        defer { git_status_list_free(statusList) }

        var lines: [String] = []
        let entryCount = git_status_list_entrycount(statusList)
        lines.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            guard let entryPointer = git_status_byindex(statusList, index) else {
                continue
            }
            let entry = entryPointer.pointee
            if entry.status == GIT_STATUS_CURRENT {
                continue
            }
            guard let path = statusPath(entry: entry) else {
                continue
            }
            lines.append("\(statusCode(status: entry.status)) \(path)")
        }

        lines.sort()

        if short {
            var output = ""
            if branch {
                let branchName = try branchNameForDisplay(repository: repository) ?? "HEAD"
                output += "## \(branchName)\n"
            }
            if !lines.isEmpty {
                output += lines.joined(separator: "\n") + "\n"
            }
            return output
        }

        let branch = (try? currentBranchName(repository: repository)) ?? "HEAD"
        if lines.isEmpty {
            return "On branch \(branch)\nnothing to commit, working tree clean\n"
        }

        let body = lines.joined(separator: "\n")
        return "On branch \(branch)\nChanges:\n\(body)\n"
    }

    private static func logOutput(localRoot: URL, oneline: Bool, limit: Int) throws -> String {
        let repository = try openRepository(path: localRoot.path)
        defer { git_repository_free(repository) }

        var walkPointer: OpaquePointer?
        try check(git_revwalk_new(&walkPointer, repository), action: "create revision walk")
        guard let walkPointer else {
            return ""
        }
        defer { git_revwalk_free(walkPointer) }

        try check(git_revwalk_sorting(walkPointer, GIT_SORT_TIME.rawValue), action: "configure revision walk")
        try check(git_revwalk_push_head(walkPointer), action: "walk from HEAD")

        var remaining = limit
        var output = ""

        while remaining > 0 {
            var oid = git_oid()
            let nextCode = git_revwalk_next(&oid, walkPointer)
            if nextCode == GIT_ITEROVER.rawValue {
                break
            }
            try check(nextCode, action: "advance revision walk")

            var commitPointer: OpaquePointer?
            try check(git_commit_lookup(&commitPointer, repository, &oid), action: "read commit")
            guard let commitPointer else {
                break
            }
            defer { git_commit_free(commitPointer) }

            let fullOID = oidString(oid)
            let message = git_commit_message(commitPointer).map { String(cString: $0) } ?? ""
            let subject = firstLine(of: message)

            if oneline {
                output += "\(String(fullOID.prefix(7))) \(subject)\n"
            } else {
                output += "commit \(fullOID)\n"
                if let author = git_commit_author(commitPointer) {
                    let name = author.pointee.name.map { String(cString: $0) } ?? "unknown"
                    let email = author.pointee.email.map { String(cString: $0) } ?? "unknown"
                    output += "Author: \(name) <\(email)>\n"
                }
                output += "\n    \(subject)\n\n"
            }

            remaining -= 1
        }

        return output
    }

    private static func makeWorktreeDiff(repository: OpaquePointer) throws -> OpaquePointer {
        var indexPointer: OpaquePointer?
        try check(git_repository_index(&indexPointer, repository), action: "open repository index")
        guard let indexPointer else {
            throw GitEngineError.runtime("failed to open repository index")
        }
        defer { git_index_free(indexPointer) }

        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)), action: "initialize diff options")

        var diffPointer: OpaquePointer?
        try check(
            git_diff_index_to_workdir(&diffPointer, repository, indexPointer, &options),
            action: "collect worktree diff"
        )
        guard let diffPointer else {
            throw GitEngineError.runtime("failed to collect worktree diff")
        }
        return diffPointer
    }

    private static func diffNameOnlyOutput(diff: OpaquePointer) -> String {
        let count = git_diff_num_deltas(diff)
        var paths: [String] = []
        paths.reserveCapacity(count)

        for index in 0..<count {
            guard let delta = git_diff_get_delta(diff, index) else {
                continue
            }
            if let path = diffDeltaPath(delta: delta.pointee) {
                paths.append(path)
            }
        }

        guard !paths.isEmpty else {
            return ""
        }
        return paths.joined(separator: "\n") + "\n"
    }

    private static func diffStatOutput(diff: OpaquePointer) throws -> String {
        let count = git_diff_num_deltas(diff)
        guard count > 0 else {
            return ""
        }

        var lines: [String] = []
        lines.reserveCapacity(count)
        var filesChanged = 0
        var insertions = 0
        var deletions = 0

        for index in 0..<count {
            guard let delta = git_diff_get_delta(diff, index) else {
                continue
            }
            guard let path = diffDeltaPath(delta: delta.pointee) else {
                continue
            }

            var patchPointer: OpaquePointer?
            try check(git_patch_from_diff(&patchPointer, diff, index), action: "read diff patch")
            let (lineAdds, lineDeletes): (Int, Int)
            if let patchPointer {
                defer { git_patch_free(patchPointer) }
                var contexts: Int = 0
                var additionsCount: Int = 0
                var deletionsCount: Int = 0
                try check(
                    git_patch_line_stats(&contexts, &additionsCount, &deletionsCount, patchPointer),
                    action: "read diff patch stats"
                )
                _ = contexts
                lineAdds = additionsCount
                lineDeletes = deletionsCount
            } else {
                lineAdds = 0
                lineDeletes = 0
            }

            filesChanged += 1
            insertions += lineAdds
            deletions += lineDeletes

            let changeCount = max(1, lineAdds + lineDeletes)
            let histogram = String(repeating: "+", count: lineAdds) + String(repeating: "-", count: lineDeletes)
            let renderedHistogram = histogram.isEmpty ? "+" : histogram
            lines.append(" \(path) | \(changeCount) \(renderedHistogram)")
        }

        var summaryParts = ["\(filesChanged) file" + (filesChanged == 1 ? "" : "s") + " changed"]
        if insertions > 0 {
            summaryParts.append("\(insertions) insertion" + (insertions == 1 ? "" : "s") + "(+)")
        }
        if deletions > 0 {
            summaryParts.append("\(deletions) deletion" + (deletions == 1 ? "" : "s") + "(-)")
        }

        return lines.joined(separator: "\n") + "\n " + summaryParts.joined(separator: ", ") + "\n"
    }

    private static func showStatOutput(repository: OpaquePointer, commit: OpaquePointer) throws -> String {
        var treePointer: OpaquePointer?
        try check(git_commit_tree(&treePointer, commit), action: "read commit tree")
        guard let treePointer else {
            throw GitEngineError.runtime("failed to read commit tree")
        }
        defer { git_tree_free(treePointer) }

        var parentTreePointer: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parentCommitPointer: OpaquePointer?
            try check(git_commit_parent(&parentCommitPointer, commit, 0), action: "read parent commit")
            if let parentCommitPointer {
                defer { git_commit_free(parentCommitPointer) }
                try check(git_commit_tree(&parentTreePointer, parentCommitPointer), action: "read parent tree")
            }
        }
        var diffOptions = git_diff_options()
        try check(git_diff_options_init(&diffOptions, UInt32(GIT_DIFF_OPTIONS_VERSION)), action: "initialize diff options")

        var diffPointer: OpaquePointer?
        try check(
            git_diff_tree_to_tree(&diffPointer, repository, parentTreePointer, treePointer, &diffOptions),
            action: "collect commit diff"
        )
        guard let diffPointer else {
            throw GitEngineError.runtime("failed to collect commit diff")
        }
        defer { git_diff_free(diffPointer) }
        if let parentTreePointer {
            git_tree_free(parentTreePointer)
        }

        let subject = firstLine(of: git_commit_message(commit).map { String(cString: $0) } ?? "")
        let commitID = oidString(git_commit_id(commit).pointee)
        let authorLine: String
        if let author = git_commit_author(commit) {
            let name = author.pointee.name.map { String(cString: $0) } ?? "unknown"
            let email = author.pointee.email.map { String(cString: $0) } ?? "unknown"
            authorLine = "Author: \(name) <\(email)>"
        } else {
            authorLine = "Author: unknown <unknown>"
        }

        let stats = try diffStatOutput(diff: diffPointer)
        return "commit \(commitID)\n\(authorLine)\n\n    \(subject)\n\n\(stats)"
    }

    private static func openRepository(path: String) throws -> OpaquePointer {
        var repository: OpaquePointer?
        try withCString(path: path) { cPath in
            try check(git_repository_open(&repository, cPath), action: "open repository")
        }

        guard let repository else {
            throw GitEngineError.runtime("failed to open repository")
        }
        return repository
    }

    private static func currentBranchName(repository: OpaquePointer) throws -> String {
        if let symbolicBranch = try symbolicHeadBranchName(repository: repository) {
            return symbolicBranch
        }

        var reference: OpaquePointer?
        let code = git_repository_head(&reference, repository)
        if code == GIT_EUNBORNBRANCH.rawValue {
            return "HEAD"
        }
        try check(code, action: "read HEAD")
        guard let reference else {
            return "HEAD"
        }
        defer { git_reference_free(reference) }
        guard let shorthand = git_reference_shorthand(reference) else {
            return "HEAD"
        }
        return String(cString: shorthand)
    }

    private static func branchNameForDisplay(repository: OpaquePointer) throws -> String? {
        if let symbolicBranch = try symbolicHeadBranchName(repository: repository) {
            return symbolicBranch
        }

        let isDetached = git_repository_head_detached(repository)
        if isDetached == 1 {
            return nil
        }
        return try currentBranchName(repository: repository)
    }

    private static func lookupHeadCommit(repository: OpaquePointer) throws -> OpaquePointer? {
        var oid = git_oid()
        let oidCode = git_reference_name_to_id(&oid, repository, "HEAD")
        if oidCode == GIT_ENOTFOUND.rawValue || oidCode == GIT_EUNBORNBRANCH.rawValue {
            return nil
        }
        try check(oidCode, action: "resolve HEAD")

        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repository, &oid), action: "load HEAD commit")
        return commit
    }

    private static func createSignature(
        repository: OpaquePointer,
        environment: [String: String]
    ) throws -> UnsafeMutablePointer<git_signature> {
        let configuredName = try configValue(repository: repository, key: "user.name")
        let configuredEmail = try configValue(repository: repository, key: "user.email")
        let authorName = environment["GIT_AUTHOR_NAME"] ?? configuredName ?? environment["USER"] ?? "user"
        let authorEmail = environment["GIT_AUTHOR_EMAIL"] ?? configuredEmail ?? "\(authorName)@example.com"

        var signature: UnsafeMutablePointer<git_signature>?
        try withCString(path: authorName) { name in
            try withCString(path: authorEmail) { email in
                try check(git_signature_now(&signature, name, email), action: "create commit signature")
            }
        }

        guard let signature else {
            throw GitEngineError.runtime("failed to create commit signature")
        }
        return signature
    }

    private static func symbolicHeadBranchName(repository: OpaquePointer) throws -> String? {
        var reference: OpaquePointer?
        let code = try withCString(path: "HEAD") { cName in
            git_reference_lookup(&reference, repository, cName)
        }
        if code == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try check(code, action: "read HEAD reference")
        guard let reference else {
            return nil
        }
        defer { git_reference_free(reference) }

        if let target = git_reference_symbolic_target(reference) {
            let targetName = String(cString: target)
            let prefix = "refs/heads/"
            if targetName.hasPrefix(prefix) {
                return String(targetName.dropFirst(prefix.count))
            }
            return targetName
        }
        return nil
    }

    private static func statusPath(entry: git_status_entry) -> String? {
        if let delta = entry.index_to_workdir ?? entry.head_to_index {
            if let path = delta.pointee.new_file.path ?? delta.pointee.old_file.path {
                return String(cString: path)
            }
        }
        return nil
    }

    private static func statusCode(status: git_status_t) -> String {
        if (status.rawValue & GIT_STATUS_WT_NEW.rawValue) != 0 && (status.rawValue & GIT_STATUS_INDEX_NEW.rawValue) == 0 {
            return "??"
        }
        if (status.rawValue & GIT_STATUS_IGNORED.rawValue) != 0 {
            return "!!"
        }

        let indexCode: Character = {
            if (status.rawValue & GIT_STATUS_INDEX_NEW.rawValue) != 0 { return "A" }
            if (status.rawValue & GIT_STATUS_INDEX_MODIFIED.rawValue) != 0 { return "M" }
            if (status.rawValue & GIT_STATUS_INDEX_DELETED.rawValue) != 0 { return "D" }
            if (status.rawValue & GIT_STATUS_INDEX_RENAMED.rawValue) != 0 { return "R" }
            if (status.rawValue & GIT_STATUS_INDEX_TYPECHANGE.rawValue) != 0 { return "T" }
            return " "
        }()

        let worktreeCode: Character = {
            if (status.rawValue & GIT_STATUS_WT_NEW.rawValue) != 0 { return "?" }
            if (status.rawValue & GIT_STATUS_WT_MODIFIED.rawValue) != 0 { return "M" }
            if (status.rawValue & GIT_STATUS_WT_DELETED.rawValue) != 0 { return "D" }
            if (status.rawValue & GIT_STATUS_WT_RENAMED.rawValue) != 0 { return "R" }
            if (status.rawValue & GIT_STATUS_WT_TYPECHANGE.rawValue) != 0 { return "T" }
            if (status.rawValue & GIT_STATUS_WT_UNREADABLE.rawValue) != 0 { return "!" }
            return " "
        }()

        return String([indexCode, worktreeCode])
    }

    private static func diffDeltaPath(delta: git_diff_delta) -> String? {
        if let path = delta.new_file.path {
            return String(cString: path)
        }
        if let path = delta.old_file.path {
            return String(cString: path)
        }
        return nil
    }

    private static func configValue(repository: OpaquePointer, key: String) throws -> String? {
        var configPointer: OpaquePointer?
        try check(git_repository_config(&configPointer, repository), action: "open repository config")
        guard let configPointer else {
            throw GitEngineError.runtime("failed to open repository config")
        }
        defer { git_config_free(configPointer) }

        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }

        let code = try withCString(path: key) { cKey in
            git_config_get_string_buf(&buffer, configPointer, cKey)
        }
        if code == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try check(code, action: "read git config")
        guard let pointer = buffer.ptr else {
            return nil
        }
        return String(cString: pointer)
    }

    private static func setConfigValue(repository: OpaquePointer, key: String, value: String) throws {
        var configPointer: OpaquePointer?
        try check(git_repository_config(&configPointer, repository), action: "open repository config")
        guard let configPointer else {
            throw GitEngineError.runtime("failed to open repository config")
        }
        defer { git_config_free(configPointer) }

        try withCString(path: key) { cKey in
            try withCString(path: value) { cValue in
                try check(git_config_set_string(configPointer, cKey, cValue), action: "write git config")
            }
        }
    }

    private static func remoteOutput(repository: OpaquePointer, verbose: Bool) throws -> String {
        var remoteNames = git_strarray(strings: nil, count: 0)
        try check(git_remote_list(&remoteNames, repository), action: "list remotes")
        defer { git_strarray_dispose(&remoteNames) }

        guard remoteNames.count > 0 else {
            return ""
        }

        var lines: [String] = []
        for index in 0..<Int(remoteNames.count) {
            guard let names = remoteNames.strings, let namePointer = names[index] else {
                continue
            }
            let name = String(cString: namePointer)
            if !verbose {
                lines.append(name)
                continue
            }

            var remotePointer: OpaquePointer?
            try withCString(path: name) { cName in
                try check(git_remote_lookup(&remotePointer, repository, cName), action: "read remote '\(name)'")
            }
            guard let remotePointer else {
                continue
            }
            defer { git_remote_free(remotePointer) }

            let fetchURL = git_remote_url(remotePointer).map { String(cString: $0) } ?? ""
            let pushURL = git_remote_pushurl(remotePointer).map { String(cString: $0) } ?? fetchURL
            lines.append("\(name)\t\(fetchURL) (fetch)")
            lines.append("\(name)\t\(pushURL) (push)")
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func withLibgit2<T>(_ body: () throws -> T) throws -> T {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        return try body()
    }

    private static func withCString<T>(path: String, body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        try path.withCString { pointer in
            try body(pointer)
        }
    }

    private static func check(_ code: Int32, action: String) throws {
        if code < 0 {
            throw GitEngineError.runtime("\(action): \(lastGitErrorMessage())")
        }
    }

    private static func oidString(_ oid: git_oid) -> String {
        var buffer = [CChar](repeating: 0, count: 41)
        _ = git_oid_tostr(&buffer, buffer.count, withUnsafePointer(to: oid) { $0 })
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func shortOIDString(_ oid: git_oid) -> String {
        let full = oidString(oid)
        return String(full.prefix(7))
    }

    private static func lastGitErrorMessage() -> String {
        guard let errorPointer = git_error_last() else {
            return "unknown libgit2 error"
        }
        let message = errorPointer.pointee.message.map { String(cString: $0) } ?? "unknown libgit2 error"
        return message
    }

    private static func firstLine(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private static func normalizeAbsolute(_ path: String) -> WorkspacePath {
        WorkspacePath(normalizing: path)
    }

    private static func basename(of path: WorkspacePath) -> String {
        path.basename
    }

    private static func parent(of path: WorkspacePath) -> WorkspacePath {
        path.dirname
    }

    private static func relativePath(of absolutePath: WorkspacePath, fromRoot root: WorkspacePath) -> String? {
        let normalizedAbsolute = absolutePath
        let normalizedRoot = root
        if normalizedAbsolute == normalizedRoot {
            return "."
        }

        let prefix = normalizedRoot.isRoot ? "/" : normalizedRoot.string + "/"
        guard normalizedAbsolute.string.hasPrefix(prefix) else {
            return nil
        }
        return String(normalizedAbsolute.string.dropFirst(prefix.count))
    }
}

private enum GitFilesystemProjection {
    private enum LocalEntryType {
        case directory(permissions: Int)
        case file(url: URL, permissions: Int)
        case symlink(target: String, permissions: Int)
    }

    static func findRepositoryRoot(
        from startPath: WorkspacePath,
        filesystem: any FileSystem
    ) async throws -> WorkspacePath? {
        var current = startPath
        while true {
            let dotGit = current.appending(".git")
            if await filesystem.exists(path: dotGit) {
                return current
            }

            if current.isRoot {
                return nil
            }
            current = current.dirname
        }
    }

    static func materialize(
        virtualRoot: WorkspacePath,
        filesystem: any FileSystem
    ) async throws -> GitRepositoryProjection {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempDirectory = tempBase.appendingPathComponent("BashGit-\(UUID().uuidString)", isDirectory: true)
        let localRoot = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)

        if await filesystem.exists(path: virtualRoot) {
            try await copyFilesystemTree(
                filesystem: filesystem,
                virtualPath: virtualRoot,
                localURL: localRoot
            )
        }

        return GitRepositoryProjection(
            virtualRoot: virtualRoot,
            temporaryDirectory: tempDirectory,
            localRoot: localRoot
        )
    }

    static func syncFromLocal(
        localRoot: URL,
        toFilesystemRoot virtualRoot: WorkspacePath,
        filesystem: any FileSystem
    ) async throws {
        if await !filesystem.exists(path: virtualRoot) {
            try await filesystem.createDirectory(path: virtualRoot, recursive: true)
        }

        let localEntries = try scanLocalEntries(localRoot: localRoot)
        let filesystemEntries = try await scanFilesystemEntries(filesystem: filesystem, root: virtualRoot)

        let localDirectoryPaths = localEntries.compactMap { key, value in
            if case .directory = value {
                return key
            }
            return nil
        }.sorted { depth(of: $0) < depth(of: $1) }

        for relativePath in localDirectoryPaths {
            let fullPath = virtualRoot.appending(relativePath)
            if await !filesystem.exists(path: fullPath) {
                try await filesystem.createDirectory(path: fullPath, recursive: true)
            }
        }

        for (relativePath, entry) in localEntries {
            let fullPath = virtualRoot.appending(relativePath)
            switch entry {
            case let .directory(permissions):
                if await !filesystem.exists(path: fullPath) {
                    try await filesystem.createDirectory(path: fullPath, recursive: true)
                }
                try? await filesystem.setPermissions(path: fullPath, permissions: POSIXPermissions(permissions))

            case let .file(url, permissions):
                if let existing = filesystemEntries[relativePath], case .directory = existing {
                    try? await filesystem.remove(path: fullPath, recursive: true)
                }
                let data = try Data(contentsOf: url)
                try await filesystem.writeFile(path: fullPath, data: data, append: false)
                try? await filesystem.setPermissions(path: fullPath, permissions: POSIXPermissions(permissions))

            case let .symlink(target, permissions):
                if await filesystem.exists(path: fullPath) {
                    try? await filesystem.remove(path: fullPath, recursive: true)
                }
                try await filesystem.createSymlink(path: fullPath, target: target)
                try? await filesystem.setPermissions(path: fullPath, permissions: POSIXPermissions(permissions))
            }
        }

        let stalePaths = filesystemEntries.keys.filter { localEntries[$0] == nil }.sorted { depth(of: $0) > depth(of: $1) }
        for relativePath in stalePaths {
            let fullPath = virtualRoot.appending(relativePath)
            try? await filesystem.remove(path: fullPath, recursive: true)
        }
    }

    private static func copyFilesystemTree(
        filesystem: any FileSystem,
        virtualPath: WorkspacePath,
        localURL: URL
    ) async throws {
        let info = try await filesystem.stat(path: virtualPath)
        if info.isDirectory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            try setPermissions(url: localURL, permissions: info.permissionBits)
            let entries = try await filesystem.listDirectory(path: virtualPath)
            for entry in entries {
                let childVirtualPath = virtualPath.appending(entry.name)
                let childLocalURL = localURL.appendingPathComponent(entry.name, isDirectory: entry.info.isDirectory)
                if entry.info.isDirectory {
                    try await copyFilesystemTree(
                        filesystem: filesystem,
                        virtualPath: childVirtualPath,
                        localURL: childLocalURL
                    )
                } else if entry.info.isSymbolicLink {
                    let target = try await filesystem.readSymlink(path: childVirtualPath)
                    try FileManager.default.createSymbolicLink(atPath: childLocalURL.path, withDestinationPath: target)
                    try setPermissions(url: childLocalURL, permissions: entry.info.permissionBits)
                } else {
                    let data = try await filesystem.readFile(path: childVirtualPath)
                    try FileManager.default.createDirectory(at: childLocalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: childLocalURL, options: .atomic)
                    try setPermissions(url: childLocalURL, permissions: entry.info.permissionBits)
                }
            }
            return
        }

        if info.isSymbolicLink {
            let target = try await filesystem.readSymlink(path: virtualPath)
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: localURL.path, withDestinationPath: target)
            try setPermissions(url: localURL, permissions: info.permissionBits)
            return
        }

        let data = try await filesystem.readFile(path: virtualPath)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
        try setPermissions(url: localURL, permissions: info.permissionBits)
    }

    private static func scanLocalEntries(localRoot: URL) throws -> [String: LocalEntryType] {
        var result: [String: LocalEntryType] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: localRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return result
        }

        for case let url as URL in enumerator {
            let relativePath = relativePath(from: localRoot, to: url)
            guard !relativePath.isEmpty else {
                continue
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755

            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                result[relativePath] = .symlink(target: target, permissions: permissions)
            } else if values.isDirectory == true {
                result[relativePath] = .directory(permissions: permissions)
            } else {
                result[relativePath] = .file(url: url, permissions: permissions)
            }
        }

        return result
    }

    private enum RemoteEntryType {
        case directory
        case file
        case symlink
    }

    private static func scanFilesystemEntries(
        filesystem: any FileSystem,
        root: WorkspacePath
    ) async throws -> [String: RemoteEntryType] {
        var entries: [String: RemoteEntryType] = [:]
        if await !filesystem.exists(path: root) {
            return entries
        }
        try await scanFilesystemEntries(
            filesystem: filesystem,
            absolutePath: root,
            relativePath: "",
            output: &entries
        )
        return entries
    }

    private static func scanFilesystemEntries(
        filesystem: any FileSystem,
        absolutePath: WorkspacePath,
        relativePath: String,
        output: inout [String: RemoteEntryType]
    ) async throws {
        let listing = try await filesystem.listDirectory(path: absolutePath)
        for entry in listing {
            let childRelative = relativePath.isEmpty ? entry.name : relativePath + "/" + entry.name
            let childAbsolute = absolutePath.appending(entry.name)
            if entry.info.isDirectory {
                output[childRelative] = .directory
                try await scanFilesystemEntries(
                    filesystem: filesystem,
                    absolutePath: childAbsolute,
                    relativePath: childRelative,
                    output: &output
                )
            } else if entry.info.isSymbolicLink {
                output[childRelative] = .symlink
            } else {
                output[childRelative] = .file
            }
        }
    }

    private static func setPermissions(url: URL, permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func relativePath(from root: URL, to path: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let absolutePath = path.standardizedFileURL.path
        if absolutePath == rootPath {
            return ""
        }
        guard absolutePath.hasPrefix(rootPath + "/") else {
            return ""
        }
        return String(absolutePath.dropFirst(rootPath.count + 1))
    }

    private static func depth(of path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }
}

private extension GitEngine {
    static func runWithLibgit2(arguments: [String], context: inout CommandContext) async -> GitExecutionResult {
        await GitEngineLibgit2.run(arguments: arguments, context: &context)
    }
}
#endif
