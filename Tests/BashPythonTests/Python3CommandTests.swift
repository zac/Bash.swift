import Foundation
import Testing
import BashPython
import Bash

@Suite("Python3 Command", .serialized)
@BashPythonTestActor
struct Python3CommandTests {
    @Test("help and version output")
    @BashPythonTestActor
    func helpAndVersion() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let help = await session.run("python3 --help")
        #expect(help.exitCode == 0)
        #expect(help.stdoutString.contains("USAGE:"))

        let shortHelp = await session.run("python3 -h")
        #expect(shortHelp.exitCode == 0)
        #expect(shortHelp.stdoutString.contains("USAGE:"))

        let version = await session.run("python --version")
        #expect(version.exitCode == 0)
        #expect(version.stdoutString.contains("Python"))
    }

    @Test("code mode and module mode parsing")
    @BashPythonTestActor
    func codeAndModuleMode() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let code = await session.run(#"python3 -c "import sys; print('mode=code'); print('args=' + ','.join(sys.argv[1:]))" one two"#)
        #expect(code.exitCode == 0)
        #expect(code.stdoutString.contains("mode=code"))
        #expect(code.stdoutString.contains("args=one,two"))

        let moduleSource = Data("import sys\nprint('mode=module')\nprint('argv=' + ','.join(sys.argv))\n".utf8)
        _ = await session.run("cat > modsample.py", stdin: moduleSource)
        let module = await session.run("python3 -m modsample 8000")
        #expect(module.exitCode == 0)
        #expect(module.stdoutString.contains("mode=module"))
        #expect(module.stdoutString.contains("8000"))
    }

    @Test("script file execution reads shell filesystem")
    @BashPythonTestActor
    func scriptFileExecutionReadsFilesystem() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let scriptSource = Data("print('from file')\nimport sys\nprint('args=' + ','.join(sys.argv[1:]))\n".utf8)
        _ = await session.run("cat > script.py", stdin: scriptSource)

        let result = await session.run("python3 script.py alpha")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.contains("from file"))
        #expect(result.stdoutString.contains("args=alpha"))
    }

    @Test("stdin mode and empty-input failure")
    @BashPythonTestActor
    func stdinModeAndEmptyInputFailure() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let stdin = await session.run("python3", stdin: Data("print('stdin')\n".utf8))
        #expect(stdin.exitCode == 0)
        #expect(stdin.stdoutString == "stdin\n")

        let empty = await session.run("python3")
        #expect(empty.exitCode == 2)
        #expect(empty.stderrString.contains("no input provided"))
    }

    @Test("missing script produces python-style error")
    @BashPythonTestActor
    func missingScriptFailure() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let result = await session.run("python3 does-not-exist.py")
        #expect(result.exitCode == 2)
        #expect(result.stderrString.contains("can't open file"))
        #expect(result.stderrString.contains("does-not-exist.py"))
    }
}
