import Foundation
import Workspace

final class ShellPermissionedFileSystem: FileSystem, @unchecked Sendable {
    let base: any FileSystem
    private let commandName: String
    private let permissionAuthorizer: any ShellPermissionAuthorizing
    private let executionControl: ExecutionControl?

    init(
        base: any FileSystem,
        commandName: String,
        permissionAuthorizer: any ShellPermissionAuthorizing,
        executionControl: ExecutionControl?
    ) {
        self.base = Self.unwrap(base)
        self.commandName = commandName
        self.permissionAuthorizer = permissionAuthorizer
        self.executionControl = executionControl
    }

    static func unwrap(_ filesystem: any FileSystem) -> any FileSystem {
        if let filesystem = filesystem as? ShellPermissionedFileSystem {
            return filesystem.base
        }
        return filesystem
    }

    func configure(rootDirectory: URL) async throws {
        try await base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: WorkspacePath) async throws -> FileInfo {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .stat,
                        path: path.string
                    )
                )
            )
        )
        return try await base.stat(path: path)
    }

    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .listDirectory,
                        path: path.string
                    )
                )
            )
        )
        return try await base.listDirectory(path: path)
    }

    func readFile(path: WorkspacePath) async throws -> Data {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .readFile,
                        path: path.string
                    )
                )
            )
        )
        return try await base.readFile(path: path)
    }

    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .writeFile,
                        path: path.string,
                        append: append
                    )
                )
            )
        )
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .createDirectory,
                        path: path.string,
                        recursive: recursive
                    )
                )
            )
        )
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .remove,
                        path: path.string,
                        recursive: recursive
                    )
                )
            )
        )
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .move,
                        sourcePath: sourcePath.string,
                        destinationPath: destinationPath.string
                    )
                )
            )
        )
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .copy,
                        sourcePath: sourcePath.string,
                        destinationPath: destinationPath.string,
                        recursive: recursive
                    )
                )
            )
        )
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func createSymlink(path: WorkspacePath, target: String) async throws {
        let normalizedTarget = try WorkspacePath(validating: target, relativeTo: path.dirname)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .createSymlink,
                        path: path.string,
                        destinationPath: normalizedTarget.string
                    )
                )
            )
        )
        try await base.createSymlink(path: path, target: target)
    }

    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .createHardLink,
                        path: path.string,
                        destinationPath: target.string
                    )
                )
            )
        )
        try await base.createHardLink(path: path, target: target)
    }

    func readSymlink(path: WorkspacePath) async throws -> String {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .readSymlink,
                        path: path.string
                    )
                )
            )
        )
        return try await base.readSymlink(path: path)
    }

    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .setPermissions,
                        path: path.string
                    )
                )
            )
        )
        try await base.setPermissions(path: path, permissions: permissions)
    }

    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .resolveRealPath,
                        path: path.string
                    )
                )
            )
        )
        return try await base.resolveRealPath(path: path)
    }

    func exists(path: WorkspacePath) async -> Bool {
        do {
            try await authorize(
                .init(
                    command: commandName,
                    kind: .filesystem(
                        ShellFilesystemPermissionRequest(
                            operation: .exists,
                            path: path.string
                        )
                    )
                )
            )
            return await base.exists(path: path)
        } catch {
            return false
        }
    }

    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    ShellFilesystemPermissionRequest(
                        operation: .glob,
                        path: normalizedPattern.string,
                        destinationPath: currentDirectory.string
                    )
                )
            )
        )
        return try await base.glob(pattern: normalizedPattern.string, currentDirectory: currentDirectory)
    }

    private func authorize(_ request: ShellPermissionRequest) async throws {
        let decision = await authorizePermissionRequest(
            request,
            using: permissionAuthorizer,
            pausing: executionControl
        )

        if case let .deny(message) = decision {
            throw ShellError.unsupported(
                message ?? defaultDenialMessage(for: request)
            )
        }
    }

    private func defaultDenialMessage(for request: ShellPermissionRequest) -> String {
        guard case let .filesystem(filesystem) = request.kind else {
            return "filesystem access denied"
        }

        let target = filesystem.path
            ?? filesystem.sourcePath
            ?? filesystem.destinationPath
            ?? "<unknown>"
        return "filesystem access denied: \(filesystem.operation.rawValue) \(target)"
    }
}
