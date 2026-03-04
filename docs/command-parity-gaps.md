# Command Parity Gaps

This document tracks major command parity gaps relative to `just-bash` and shell expectations.

| Command | Current Status | Priority | Remaining Gaps | Test Coverage |
| --- | --- | --- | --- | --- |
| Job control (`&`, `$!`, `jobs`, `fg`, `wait`, `ps`, `kill`) | Background execution, pseudo-PID tracking, process listing, and signal-style termination are supported for in-process commands with buffered stdout/stderr handoff. | Medium | No stopped-job state transitions (`bg`, `disown`, `SIGTSTP`/`SIGCONT`) and no true host-process/TTY semantics. | `Tests/BashTests/ParserAndFilesystemTests.swift`, `Tests/BashTests/SessionIntegrationTests.swift` |
| Shell language (`$(...)`, `for`, functions) | Command substitution and simple function definitions are supported, plus a focused `for ... in ...; do ...; done` form with trailing redirection support. | High | No general shell grammar for control flow (`if`, `while`, `case`), positional params, or full function semantics. `for` support is intentionally limited to the simple `in` form. | `Tests/BashTests/SessionIntegrationTests.swift` |
| `wget` | Basic `wget` emulation is available (`--version`, `-q`, `-O/--output-document`, URL fetch via in-process `curl` path). | Medium | No recursive download modes, robots handling, retry/progress parity, auth matrix, or full GNU `wget` flag compatibility. | `Tests/BashTests/SessionIntegrationTests.swift`, `Tests/BashTests/CommandCoverageTests.swift` |
| `python3` / `python` | Embedded CPython with strict shell-filesystem shims; supports `-c`, `-m`, script file/stdin execution, and core stdlib + filesystem interoperability. | Medium | Broader CLI flag parity, full stdlib/native-extension parity, packaging (`pip`) support, and richer compatibility with process APIs (intentionally blocked in strict mode). | `Tests/BashPythonTests/Python3CommandTests.swift`, `Tests/BashPythonTests/CPythonRuntimeIntegrationTests.swift` |
