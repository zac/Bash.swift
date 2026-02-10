import Foundation
import BashPython
import Bash

enum PythonTestSupport {
    static func makeTempDirectory(prefix: String = "BashPythonTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSession() async throws -> (session: BashSession, root: URL) {
        let root = try makeTempDirectory()
        let session = try await BashSession(rootDirectory: root)
        await session.registerPython()
        return (session, root)
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct EchoPythonRuntime: PythonRuntime {
    func execute(
        request: PythonExecutionRequest,
        filesystem: any ShellFilesystem
    ) async -> PythonExecutionResult {
        _ = filesystem

        let args = request.arguments.joined(separator: ",")
        let output = "mode=\(request.mode.rawValue);script=\(request.scriptPath ?? "");cwd=\(request.currentDirectory);args=\(args);source=\(request.source)\n"
        return PythonExecutionResult(stdout: output, stderr: "", exitCode: 0)
    }
}
