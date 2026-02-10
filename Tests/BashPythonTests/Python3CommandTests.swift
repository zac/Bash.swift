import Foundation
import Testing
import BashPython
import Bash

@Suite("Python3 Command")
struct Python3CommandTests {
    @Test("help and version output")
    func helpAndVersion() async throws {
        await BashPython.setRuntime(EchoPythonRuntime())

        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let help = await session.run("python3 --help")
        #expect(help.exitCode == 0)
        #expect(help.stdoutString.contains("USAGE:"))

        let version = await session.run("python --version")
        #expect(version.exitCode == 0)
        #expect(version.stdoutString.contains("Python 3"))
    }

    @Test("code mode and module mode parsing")
    func codeAndModuleMode() async throws {
        await BashPython.setRuntime(EchoPythonRuntime())

        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let code = await session.run("python3 -c \"print('hi')\" one two")
        #expect(code.exitCode == 0)
        #expect(code.stdoutString.contains("mode=code"))
        #expect(code.stdoutString.contains("script=-c"))
        #expect(code.stdoutString.contains("args=one,two"))
        #expect(code.stdoutString.contains("source=print('hi')"))

        let module = await session.run("python3 -m http.server 8000")
        #expect(module.exitCode == 0)
        #expect(module.stdoutString.contains("mode=module"))
        #expect(module.stdoutString.contains("script=http.server"))
        #expect(module.stdoutString.contains("args=8000"))
        #expect(module.stdoutString.contains("source=http.server"))
    }

    @Test("script file execution reads shell filesystem")
    func scriptFileExecutionReadsFilesystem() async throws {
        await BashPython.setRuntime(EchoPythonRuntime())

        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        _ = await session.run("printf \"print('from file')\\n\" > script.py")

        let result = await session.run("python3 script.py alpha")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.contains("mode=code"))
        #expect(result.stdoutString.contains("script=script.py"))
        #expect(result.stdoutString.contains("args=alpha"))
        #expect(result.stdoutString.contains("source=print('from file')"))
    }

    @Test("stdin mode and empty-input failure")
    func stdinModeAndEmptyInputFailure() async throws {
        await BashPython.setRuntime(EchoPythonRuntime())

        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let stdin = await session.run("python3", stdin: Data("print('stdin')\n".utf8))
        #expect(stdin.exitCode == 0)
        #expect(stdin.stdoutString.contains("script=<stdin>"))
        #expect(stdin.stdoutString.contains("source=print('stdin')"))

        let empty = await session.run("python3")
        #expect(empty.exitCode == 2)
        #expect(empty.stderrString.contains("no input provided"))
    }

    @Test("missing script produces python-style error")
    func missingScriptFailure() async throws {
        await BashPython.setRuntime(EchoPythonRuntime())

        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let result = await session.run("python3 does-not-exist.py")
        #expect(result.exitCode == 2)
        #expect(result.stderrString.contains("can't open file"))
        #expect(result.stderrString.contains("does-not-exist.py"))
    }
}
