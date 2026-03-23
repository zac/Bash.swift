import Foundation

final class PermissionedShellFilesystem: ShellFilesystem, @unchecked Sendable {
    let base: any ShellFilesystem
    private let commandName: String
    private let permissionAuthorizer: any PermissionAuthorizing
    private let executionControl: ExecutionControl?

    init(
        base: any ShellFilesystem,
        commandName: String,
        permissionAuthorizer: any PermissionAuthorizing,
        executionControl: ExecutionControl?
    ) {
        self.base = Self.unwrap(base)
        self.commandName = commandName
        self.permissionAuthorizer = permissionAuthorizer
        self.executionControl = executionControl
    }

    static func unwrap(_ filesystem: any ShellFilesystem) -> any ShellFilesystem {
        if let filesystem = filesystem as? PermissionedShellFilesystem {
            return filesystem.base
        }
        return filesystem
    }

    func configure(rootDirectory: URL) async throws {
        try await base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: String) async throws -> FileInfo {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .stat,
                        path: normalized
                    )
                )
            )
        )
        return try await base.stat(path: normalized)
    }

    func listDirectory(path: String) async throws -> [DirectoryEntry] {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .listDirectory,
                        path: normalized
                    )
                )
            )
        )
        return try await base.listDirectory(path: normalized)
    }

    func readFile(path: String) async throws -> Data {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .readFile,
                        path: normalized
                    )
                )
            )
        )
        return try await base.readFile(path: normalized)
    }

    func writeFile(path: String, data: Data, append: Bool) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .writeFile,
                        path: normalized,
                        append: append
                    )
                )
            )
        )
        try await base.writeFile(path: normalized, data: data, append: append)
    }

    func createDirectory(path: String, recursive: Bool) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .createDirectory,
                        path: normalized,
                        recursive: recursive
                    )
                )
            )
        )
        try await base.createDirectory(path: normalized, recursive: recursive)
    }

    func remove(path: String, recursive: Bool) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .remove,
                        path: normalized,
                        recursive: recursive
                    )
                )
            )
        )
        try await base.remove(path: normalized, recursive: recursive)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let normalizedSource = try normalizedPath(sourcePath)
        let normalizedDestination = try normalizedPath(destinationPath)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .move,
                        sourcePath: normalizedSource,
                        destinationPath: normalizedDestination
                    )
                )
            )
        )
        try await base.move(from: normalizedSource, to: normalizedDestination)
    }

    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        let normalizedSource = try normalizedPath(sourcePath)
        let normalizedDestination = try normalizedPath(destinationPath)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .copy,
                        sourcePath: normalizedSource,
                        destinationPath: normalizedDestination,
                        recursive: recursive
                    )
                )
            )
        )
        try await base.copy(from: normalizedSource, to: normalizedDestination, recursive: recursive)
    }

    func createSymlink(path: String, target: String) async throws {
        let normalizedPath = try normalizedPath(path)
        try PathUtils.validate(target)
        let normalizedTarget = PathUtils.normalize(
            path: target,
            currentDirectory: PathUtils.dirname(normalizedPath)
        )
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .createSymlink,
                        path: normalizedPath,
                        destinationPath: normalizedTarget
                    )
                )
            )
        )
        try await base.createSymlink(path: normalizedPath, target: target)
    }

    func createHardLink(path: String, target: String) async throws {
        let normalizedLinkPath = try normalizedPath(path)
        let normalizedTarget = try normalizedPath(target)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .createHardLink,
                        path: normalizedLinkPath,
                        destinationPath: normalizedTarget
                    )
                )
            )
        )
        try await base.createHardLink(path: normalizedLinkPath, target: normalizedTarget)
    }

    func readSymlink(path: String) async throws -> String {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .readSymlink,
                        path: normalized
                    )
                )
            )
        )
        return try await base.readSymlink(path: normalized)
    }

    func setPermissions(path: String, permissions: Int) async throws {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .setPermissions,
                        path: normalized
                    )
                )
            )
        )
        try await base.setPermissions(path: normalized, permissions: permissions)
    }

    func resolveRealPath(path: String) async throws -> String {
        let normalized = try normalizedPath(path)
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .resolveRealPath,
                        path: normalized
                    )
                )
            )
        )
        return try await base.resolveRealPath(path: normalized)
    }

    func exists(path: String) async -> Bool {
        do {
            let normalized = try normalizedPath(path)
            try await authorize(
                .init(
                    command: commandName,
                    kind: .filesystem(
                        FilesystemPermissionRequest(
                            operation: .exists,
                            path: normalized
                        )
                    )
                )
            )
            return await base.exists(path: normalized)
        } catch {
            return false
        }
    }

    func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        try PathUtils.validate(pattern)
        let normalizedCurrentDirectory = try normalizedPath(currentDirectory)
        let normalizedPattern = PathUtils.normalize(
            path: pattern,
            currentDirectory: normalizedCurrentDirectory
        )
        try await authorize(
            .init(
                command: commandName,
                kind: .filesystem(
                    FilesystemPermissionRequest(
                        operation: .glob,
                        path: normalizedPattern,
                        destinationPath: normalizedCurrentDirectory
                    )
                )
            )
        )
        return try await base.glob(
            pattern: normalizedPattern,
            currentDirectory: normalizedCurrentDirectory
        )
    }

    private func normalizedPath(_ path: String) throws -> String {
        try PathUtils.validate(path)
        return PathUtils.normalize(path: path, currentDirectory: "/")
    }

    private func authorize(_ request: PermissionRequest) async throws {
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

    private func defaultDenialMessage(for request: PermissionRequest) -> String {
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
