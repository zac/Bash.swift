@_exported import Workspace
import Foundation

public typealias WorkspaceFilesystem = ShellFilesystem

public struct FileInfo: Sendable, Codable {
    public var path: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: UInt64
    public var permissions: Int
    public var modificationDate: Date?

    public init(
        path: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }
}

public struct DirectoryEntry: Sendable, Codable {
    public var name: String
    public var info: FileInfo

    public init(name: String, info: FileInfo) {
        self.name = name
        self.info = info
    }
}

public protocol ShellFilesystem: AnyObject, Sendable {
    func configure(rootDirectory: URL) async throws

    func stat(path: String) async throws -> FileInfo
    func listDirectory(path: String) async throws -> [DirectoryEntry]
    func readFile(path: String) async throws -> Data
    func writeFile(path: String, data: Data, append: Bool) async throws
    func createDirectory(path: String, recursive: Bool) async throws
    func remove(path: String, recursive: Bool) async throws
    func move(from sourcePath: String, to destinationPath: String) async throws
    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws
    func createSymlink(path: String, target: String) async throws
    func createHardLink(path: String, target: String) async throws
    func readSymlink(path: String) async throws -> String
    func setPermissions(path: String, permissions: Int) async throws
    func resolveRealPath(path: String) async throws -> String

    func exists(path: String) async -> Bool
    func glob(pattern: String, currentDirectory: String) async throws -> [String]
}

public extension ShellFilesystem where Self: FileSystem {
    func stat(path: String) async throws -> FileInfo {
        let info = try await (self as any FileSystem).stat(path: try workspacePath(path))
        return FileInfo(
            path: info.path.string,
            isDirectory: info.kind == .directory,
            isSymbolicLink: info.kind == .symlink,
            size: info.size,
            permissions: Int(info.permissions.rawValue),
            modificationDate: info.modificationDate
        )
    }

    func listDirectory(path: String) async throws -> [DirectoryEntry] {
        let entries = try await (self as any FileSystem).listDirectory(path: try workspacePath(path))
        return entries.map { entry in
            DirectoryEntry(
                name: entry.name,
                info: FileInfo(
                    path: entry.info.path.string,
                    isDirectory: entry.info.kind == .directory,
                    isSymbolicLink: entry.info.kind == .symlink,
                    size: entry.info.size,
                    permissions: Int(entry.info.permissions.rawValue),
                    modificationDate: entry.info.modificationDate
                )
            )
        }
    }

    func readFile(path: String) async throws -> Data {
        try await (self as any FileSystem).readFile(path: try workspacePath(path))
    }

    func writeFile(path: String, data: Data, append: Bool) async throws {
        try await (self as any FileSystem).writeFile(path: try workspacePath(path), data: data, append: append)
    }

    func createDirectory(path: String, recursive: Bool) async throws {
        try await (self as any FileSystem).createDirectory(path: try workspacePath(path), recursive: recursive)
    }

    func remove(path: String, recursive: Bool) async throws {
        try await (self as any FileSystem).remove(path: try workspacePath(path), recursive: recursive)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        try await (self as any FileSystem).move(
            from: try workspacePath(sourcePath),
            to: try workspacePath(destinationPath)
        )
    }

    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try await (self as any FileSystem).copy(
            from: try workspacePath(sourcePath),
            to: try workspacePath(destinationPath),
            recursive: recursive
        )
    }

    func createSymlink(path: String, target: String) async throws {
        try await (self as any FileSystem).createSymlink(path: try workspacePath(path), target: target)
    }

    func createHardLink(path: String, target: String) async throws {
        try await (self as any FileSystem).createHardLink(
            path: try workspacePath(path),
            target: try workspacePath(target)
        )
    }

    func readSymlink(path: String) async throws -> String {
        try await (self as any FileSystem).readSymlink(path: try workspacePath(path))
    }

    func setPermissions(path: String, permissions: Int) async throws {
        try await (self as any FileSystem).setPermissions(
            path: try workspacePath(path),
            permissions: POSIXPermissions(permissions)
        )
    }

    func resolveRealPath(path: String) async throws -> String {
        let realPath = try await (self as any FileSystem).resolveRealPath(path: try workspacePath(path))
        return realPath.string
    }

    func exists(path: String) async -> Bool {
        do {
            return await (self as any FileSystem).exists(path: try workspacePath(path))
        } catch {
            return false
        }
    }

    func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        let matches = try await (self as any FileSystem).glob(
            pattern: pattern,
            currentDirectory: try workspacePath(currentDirectory)
        )
        return matches.map(\.string)
    }
}

extension ReadWriteFilesystem: ShellFilesystem {}
extension InMemoryFilesystem: ShellFilesystem {}
extension MountableFilesystem: ShellFilesystem {}
extension OverlayFilesystem: ShellFilesystem {}
extension SandboxFilesystem: ShellFilesystem {}
extension SecurityScopedFilesystem: ShellFilesystem {}
extension PermissionedFileSystem: ShellFilesystem {}

enum PathUtils {
    static func validate(_ path: String) throws {
        if path.contains("\u{0}") {
            throw ShellError.invalidPath(path)
        }
    }

    static func normalize(path: String, currentDirectory: String) -> String {
        if path.isEmpty {
            return currentDirectory
        }

        let base: [String]
        if path.hasPrefix("/") {
            base = []
        } else {
            base = splitComponents(currentDirectory)
        }

        var parts = base
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                }
            default:
                parts.append(String(piece))
            }
        }

        return "/" + parts.joined(separator: "/")
    }

    static func splitComponents(_ absolutePath: String) -> [String] {
        absolutePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func basename(_ path: String) -> String {
        let normalized = path == "/" ? "/" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/" || normalized.isEmpty {
            return "/"
        }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    static func dirname(_ path: String) -> String {
        let normalized = normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            return "/"
        }

        var parts = splitComponents(normalized)
        _ = parts.popLast()
        if parts.isEmpty {
            return "/"
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        if rhs.hasPrefix("/") {
            return normalize(path: rhs, currentDirectory: "/")
        }

        let separator = lhs.hasSuffix("/") ? "" : "/"
        return normalize(path: lhs + separator + rhs, currentDirectory: "/")
    }

    static func containsGlob(_ token: String) -> Bool {
        token.contains("*") || token.contains("?") || token.contains("[")
    }

    static func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "*" {
                regex += ".*"
            } else if char == "?" {
                regex += "."
            } else if char == "[" {
                if let closeIndex = pattern[index...].firstIndex(of: "]") {
                    let range = pattern.index(after: index)..<closeIndex
                    regex += "[" + String(pattern[range]) + "]"
                    index = closeIndex
                } else {
                    regex += "\\["
                }
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = pattern.index(after: index)
        }

        regex += "$"
        return regex
    }
}

private func workspacePath(_ path: String, currentDirectory: String = "/") throws -> WorkspacePath {
    try PathUtils.validate(path)
    let normalized = PathUtils.normalize(path: path, currentDirectory: currentDirectory)
    return try WorkspacePath(validating: normalized)
}
