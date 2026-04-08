import ArgumentParser
import Foundation
import BashCore

struct ChmodCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("R"), .customLong("recursive")], help: "Change files and directories recursively")
        var recursive = false

        @Argument(help: "Mode followed by files and directories")
        var values: [String] = []
    }

    static let name = "chmod"
    static let overview = "Change file mode bits"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.values.count >= 2 else {
            context.writeStderr("chmod: expected mode and file operands\n")
            return 1
        }

        let modeText = options.values[0]
        let mode: ModeSpec
        do {
            mode = try parseMode(modeText)
        } catch {
            context.writeStderr("chmod: invalid mode: \(modeText)\n")
            return 1
        }

        var failed = false
        for path in options.values.dropFirst() {
            do {
                let resolved = context.resolvePath(path)
                try await applyMode(
                    mode,
                    to: resolved,
                    recursive: options.recursive,
                    filesystem: context.filesystem
                )
            } catch {
                context.writeStderr("chmod: \(path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    private static func applyMode(
        _ mode: ModeSpec,
        to path: WorkspacePath,
        recursive: Bool,
        filesystem: any FileSystem
    ) async throws {
        let info = try await filesystem.stat(path: path)
        let permissions = try mode.resolve(currentPermissions: info.permissionBits)
        try await filesystem.setPermissions(path: path, permissions: permissions)
        guard recursive else {
            return
        }

        guard info.isDirectory else {
            return
        }

        let entries = try await filesystem.listDirectory(path: path)
        for entry in entries {
            try await applyMode(
                mode,
                to: path.appending(entry.name),
                recursive: true,
                filesystem: filesystem
            )
        }
    }

    private enum ModeSpec {
        case absolute(Int)
        case symbolic([SymbolicOperation])

        func resolve(currentPermissions: Int) throws -> POSIXPermissions {
            switch self {
            case let .absolute(value):
                return POSIXPermissions(value)
            case let .symbolic(operations):
                let resolved = operations.reduce(currentPermissions) { partial, operation in
                    operation.apply(to: partial)
                }
                return POSIXPermissions(resolved)
            }
        }
    }

    private struct SymbolicOperation {
        let classes: Set<Character>
        let op: Character
        let perms: Set<Character>

        func apply(to mode: Int) -> Int {
            let targets = resolvedClasses()
            let permissionMask = mask(for: targets, perms: perms)
            let classMask = mask(for: targets, perms: Set(["r", "w", "x"]))

            switch op {
            case "+":
                return mode | permissionMask
            case "-":
                return mode & ~permissionMask
            case "=":
                return (mode & ~classMask) | permissionMask
            default:
                return mode
            }
        }

        private func resolvedClasses() -> Set<Character> {
            if classes.isEmpty || classes.contains("a") {
                return ["u", "g", "o"]
            }
            return classes
        }

        private func mask(for classes: Set<Character>, perms: Set<Character>) -> Int {
            var value = 0
            for userClass in classes {
                for perm in perms {
                    switch (userClass, perm) {
                    case ("u", "r"): value |= 0o400
                    case ("u", "w"): value |= 0o200
                    case ("u", "x"): value |= 0o100
                    case ("g", "r"): value |= 0o040
                    case ("g", "w"): value |= 0o020
                    case ("g", "x"): value |= 0o010
                    case ("o", "r"): value |= 0o004
                    case ("o", "w"): value |= 0o002
                    case ("o", "x"): value |= 0o001
                    default: continue
                    }
                }
            }
            return value
        }
    }

    private static func parseMode(_ raw: String) throws -> ModeSpec {
        if let absolute = Int(raw, radix: 8) {
            return .absolute(absolute)
        }

        let operations = try raw.split(separator: ",").map { chunk -> SymbolicOperation in
            let part = String(chunk)
            guard let opIndex = part.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "=" }) else {
                throw ShellError.unsupported("invalid symbolic mode")
            }

            let classes = Set(part[..<opIndex])
            let op = part[opIndex]
            let perms = Set(part[part.index(after: opIndex)...])
            guard !perms.isEmpty, perms.allSatisfy({ $0 == "r" || $0 == "w" || $0 == "x" }) else {
                throw ShellError.unsupported("invalid symbolic mode")
            }
            guard classes.allSatisfy({ $0 == "u" || $0 == "g" || $0 == "o" || $0 == "a" }) else {
                throw ShellError.unsupported("invalid symbolic mode")
            }

            return SymbolicOperation(classes: classes, op: op, perms: perms)
        }

        guard !operations.isEmpty else {
            throw ShellError.unsupported("invalid symbolic mode")
        }

        return .symbolic(operations)
    }
}

struct FileCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Paths to inspect")
        var paths: [String] = []
    }

    static let name = "file"
    static let overview = "Determine file type"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("file: missing operand\n")
            return 1
        }

        var failed = false
        for path in options.paths {
            let resolved = context.resolvePath(path)
            do {
                let info = try await context.filesystem.stat(path: resolved)
                let description: String
                if info.isDirectory {
                    description = "directory"
                } else if info.isSymbolicLink {
                    description = "symbolic link"
                } else {
                    let data = try await context.filesystem.readFile(path: resolved)
                    if data.isEmpty {
                        description = "empty"
                    } else if CommandText.isLikelyText(data) {
                        description = "ASCII text"
                    } else {
                        description = "data"
                    }
                }
                context.writeStdout("\(path): \(description)\n")
            } catch {
                context.writeStderr("file: \(path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }
}
