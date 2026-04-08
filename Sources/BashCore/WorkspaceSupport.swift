@_exported import Workspace

package func shellPath(
    _ path: String,
    currentDirectory: String = "/"
) throws -> WorkspacePath {
    try WorkspacePath(
        validating: path,
        relativeTo: WorkspacePath(normalizing: currentDirectory)
    )
}

package func validateWorkspacePath(_ path: String) throws {
    _ = try WorkspacePath(validating: path)
}

package func normalizeWorkspacePath(
    path: String,
    currentDirectory: String
) -> String {
    WorkspacePath(
        normalizing: path,
        relativeTo: WorkspacePath(normalizing: currentDirectory)
    ).string
}

public extension FileInfo {
    var isDirectory: Bool {
        kind == .directory
    }

    var isSymbolicLink: Bool {
        kind == .symlink
    }

    var permissionBits: Int {
        Int(permissions.rawValue)
    }
}

public extension POSIXPermissions {
    var intValue: Int {
        Int(rawValue)
    }
}
