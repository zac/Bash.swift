# Command Parity Gaps

This document tracks major command parity gaps relative to `just-bash` and shell expectations.

| Command | Current Status | Priority | Remaining Gaps | Test Coverage |
| --- | --- | --- | --- | --- |
| `python3` / `python` | Embedded CPython with strict shell-filesystem shims; supports `-c`, `-m`, script file/stdin execution, and core stdlib + filesystem interoperability. | Medium | Broader CLI flag parity, full stdlib/native-extension parity, packaging (`pip`) support, and richer compatibility with process APIs (intentionally blocked in strict mode). | `Tests/BashPythonTests/Python3CommandTests.swift`, `Tests/BashPythonTests/CPythonRuntimeIntegrationTests.swift` |
