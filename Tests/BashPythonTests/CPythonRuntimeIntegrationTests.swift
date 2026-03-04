import Foundation
import Testing
import Bash
import BashPython

#if os(macOS)
@Suite("CPython Runtime Integration", .serialized)
@BashPythonTestActor
struct CPythonRuntimeIntegrationTests {
    @Test("runtime availability and version")
    @BashPythonTestActor
    func runtimeAvailabilityAndVersion() async throws {
        #expect(BashPython.isCPythonRuntimeAvailable())
        let runtime = await PythonRuntimeRegistry.shared.currentRuntime()
        let version = await runtime.versionString()
        #expect(version.contains("Python"))
        #expect(version.contains("CPython") || version.contains("."))
    }

    @Test("core stdlib modules execute")
    @BashPythonTestActor
    func coreStdlibModules() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let result = await session.run(#"python3 -c "import json, re, math, datetime, collections, itertools, functools, hashlib, base64; print(json.dumps({'ok': True, 'sqrt': int(math.sqrt(16))}))""#)
        #expect(result.exitCode == 0)
        #expect(result.stderrString.isEmpty)
        #expect(result.stdoutString.contains("\"ok\": true") || result.stdoutString.contains("\"ok\":true"))
        #expect(result.stdoutString.contains("\"sqrt\": 4") || result.stdoutString.contains("\"sqrt\":4"))
    }

    @Test("filesystem interoperability between shell and python")
    @BashPythonTestActor
    func filesystemInteroperability() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p /tmp/pyfs")
        _ = await session.run("printf 'from bash' > /tmp/pyfs/bash.txt")

        let read = await session.run(#"python3 -c "print(open('/tmp/pyfs/bash.txt').read())""#)
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "from bash\n")

        let write = await session.run(#"python3 -c "open('/tmp/pyfs/python.txt', 'w').write('from python')""#)
        #expect(write.exitCode == 0)

        let cat = await session.run("cat /tmp/pyfs/python.txt")
        #expect(cat.exitCode == 0)
        #expect(cat.stdoutString == "from python")
    }

    @Test("pathlib glob shutil tempfile flow")
    @BashPythonTestActor
    func pathlibGlobShutilTempfileFlow() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let script = #"python3 -c "import glob, pathlib, shutil, tempfile; pathlib.Path('/tmp/cpy').mkdir(parents=True, exist_ok=True); pathlib.Path('/tmp/cpy/a.txt').write_text('A'); shutil.copy('/tmp/cpy/a.txt', '/tmp/cpy/b.txt'); print(sorted(glob.glob('/tmp/cpy/*.txt'))); print(pathlib.Path('/tmp/cpy/b.txt').read_text()); tmp = tempfile.TemporaryDirectory(prefix='bashpy-'); p = pathlib.Path(tmp.name) / 'x.txt'; p.write_text('temp'); print(p.read_text()); tmp.cleanup()""#

        let result = await session.run(script)
        #expect(result.exitCode == 0)
        #expect(result.stderrString.isEmpty)
        #expect(result.stdoutString.contains("a.txt"))
        #expect(result.stdoutString.contains("b.txt"))
        #expect(result.stdoutString.contains("A\n"))
        #expect(result.stdoutString.contains("temp\n"))
    }

    @Test("env cwd argv stdin and local import")
    @BashPythonTestActor
    func envCwdArgvStdinAndLocalImport() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p /tmp/pyimport")
        _ = await session.run("printf 'def answer():\n    return 42\n' > /tmp/pyimport/mymodule.py")
        _ = await session.run("cd /tmp/pyimport")
        _ = await session.run("export MY_FLAG=enabled")

        let envAndImport = await session.run(#"python3 -c "import os, sys, mymodule; print(os.getcwd()); print(os.environ.get('MY_FLAG')); print(sys.argv[1:]); print(mymodule.answer())" one two"#)
        #expect(envAndImport.exitCode == 0)
        #expect(envAndImport.stderrString.isEmpty)
        #expect(envAndImport.stdoutString.contains("/tmp/pyimport\n"))
        #expect(envAndImport.stdoutString.contains("enabled\n"))
        #expect(envAndImport.stdoutString.contains("['one', 'two']\n"))
        #expect(envAndImport.stdoutString.contains("42\n"))

        let stdin = await session.run("python3 -c \"print(input())\"", stdin: Data("hello-from-stdin\n".utf8))
        #expect(stdin.exitCode == 0)
        #expect(stdin.stdoutString == "hello-from-stdin\n")
    }

    @Test("strict mode blocks subprocess ctypes and os.system")
    @BashPythonTestActor
    func strictModeBlocksEscapes() async throws {
        let (session, root) = try await PythonTestSupport.makeSession()
        defer { PythonTestSupport.removeDirectory(root) }

        let subprocessImport = await session.run(#"python3 -c "import subprocess""#)
        #expect(subprocessImport.exitCode == 1)
        #expect(subprocessImport.stderrString.contains("disabled"))

        let ctypesImport = await session.run(#"python3 -c "import ctypes""#)
        #expect(ctypesImport.exitCode == 1)
        #expect(ctypesImport.stderrString.contains("disabled"))

        let osSystem = await session.run(#"python3 -c "import os; os.system('echo hi')""#)
        #expect(osSystem.exitCode == 1)
        #expect(osSystem.stderrString.contains("PermissionError"))
    }

    @Test("in-memory filesystem path works")
    @BashPythonTestActor
    func inMemoryFilesystemWorks() async throws {
        let session = try await PythonTestSupport.makeInMemorySession()

        _ = await session.run("mkdir -p /tmp")
        _ = await session.run("printf 'memory' > /tmp/input.txt")

        let py = await session.run(#"python3 -c "data=open('/tmp/input.txt').read(); open('/tmp/output.txt', 'w').write(data + '-ok')""#)
        #expect(py.exitCode == 0)

        let cat = await session.run("cat /tmp/output.txt")
        #expect(cat.exitCode == 0)
        #expect(cat.stdoutString == "memory-ok")
    }
}
#endif
