# AGENTS.md

This file is a contributor guide for `Bash`.

## Project Goal

`Bash` is an in-process, stateful, emulated shell for Swift apps.

Key properties:
- Shell commands run inside Swift (no subprocess spawning).
- Session state persists across runs (`cwd`, environment, history).
- Commands mutate a pluggable filesystem abstraction.
- Shell behavior is practical and test-first for app and LLM use-cases.

## Tech + Platform Baseline

- Swift tools: `6.2`
- Package: SwiftPM library products `Bash`, `BashSQLite` (optional), `BashPython` (optional), `BashGit` (optional)
- Parsing/help: [`swift-argument-parser`](https://github.com/apple/swift-argument-parser)
- Tests: Swift Testing (`import Testing`), not XCTest
- Package platforms:
  - macOS 13+
  - iOS 16+
  - tvOS 16+
  - watchOS 9+

## Core Architecture

### High-level flow

1. `BashSession.run(_:)` receives a command line.
2. `ShellLexer` tokenizes input (quotes, escapes, operators).
3. `ShellParser` builds a parsed line (pipelines + chain segments + redirections).
4. `ShellExecutor` executes:
   - variable expansion
   - optional glob expansion
   - pipeline plumbing (`stdout` -> next `stdin`)
   - redirections (`>`, `>>`, `<`, `2>`, `2>&1`)
   - chain short-circuiting (`&&`, `||`, `;`)
5. `BashSession` persists updated state and returns `CommandResult`.

### Session + state

Primary entry point:
- `Sources/Bash/BashSession.swift`

Important behavior:
- `BashSession` is an `actor`.
- `run` returns `CommandResult` even on command failures.
- Parser/runtime faults surface as `exitCode = 2` with stderr text.
- Unknown commands return `127`.
- Default layout `.unixLike` scaffolds `/home/user`, `/bin`, `/usr/bin`, `/tmp`.
- Built-ins are registered at startup and stubs are created under `/bin` and `/usr/bin`.

### Command abstraction

Command interface:
- `Sources/Bash/Commands/BuiltinCommand.swift`

Pattern:
- Each command conforms to `BuiltinCommand`.
- Options are `ParsableArguments`.
- `--help` and argument validation come from ArgumentParser.
- Runtime receives mutable `CommandContext` (stdin/stdout/stderr + env/cwd/filesystem).

## Command Code Map

Registration list:
- `Sources/Bash/Commands/DefaultCommands.swift`

Shared helpers:
- `Sources/Bash/Commands/CommandSupport.swift`

File operation commands:
- `Sources/Bash/Commands/File/BasicFileCommands.swift`
  - `cat`, `readlink`, `rm`, `stat`, `touch`
- `Sources/Bash/Commands/File/CopyMoveLinkCommands.swift`
  - `cp`, `ln`, `mv`
- `Sources/Bash/Commands/File/DirectoryCommands.swift`
  - `ls`, `mkdir`, `rmdir`
- `Sources/Bash/Commands/File/MetadataCommands.swift`
  - `chmod`, `file`
- `Sources/Bash/Commands/File/TreeCommand.swift`
  - `tree`

Text/search/transform commands:
- `Sources/Bash/Commands/Text/DiffCommand.swift`
  - `diff`
- `Sources/Bash/Commands/Text/SearchCommands.swift`
  - `grep` (+ aliases), `rg`
- `Sources/Bash/Commands/Text/LineCommands.swift`
  - `head`, `tail`, `wc`
- `Sources/Bash/Commands/Text/TransformCommands.swift`
  - `sort`, `uniq`, `cut`, `tr`
- `Sources/Bash/Commands/Text/AwkCommand.swift`
  - `awk`
- `Sources/Bash/Commands/Text/SedCommand.swift`
  - `sed`
- `Sources/Bash/Commands/Text/XargsCommand.swift`
  - `xargs`

Formatting/hash commands:
- `Sources/Bash/Commands/FormattingCommands.swift`
  - `printf`, `base64`, `sha256sum`, `sha1sum`, `md5sum`

Compression/archive commands:
- `Sources/Bash/Commands/CompressionCommands.swift`
  - `gzip`, `gunzip`, `zcat`, `zip`, `unzip`, `tar`

Data processing commands:
- `Sources/Bash/Commands/DataCommands.swift`
  - `jq`, `yq`, `xan`

Navigation/environment commands:
- `Sources/Bash/Commands/NavigationCommands.swift`
  - `basename`, `cd`, `dirname`, `du`, `echo`, `env`, `export`, `find`, `printenv`, `pwd`, `tee`

Utility commands:
- `Sources/Bash/Commands/UtilityCommands.swift`
  - `clear`, `date`, `hostname`, `false`, `whoami`, `help`, `history`, `seq`, `sleep`, `time`, `timeout`, `true`, `which`

Network commands:
- `Sources/Bash/Commands/NetworkCommands.swift`
  - `curl`
- `Sources/Bash/Commands/Network/HtmlToMarkdownCommand.swift`
  - `html-to-markdown`

Optional module commands:
- `Sources/BashSQLite/*`
  - `sqlite3` (register via `BashSession.registerSQLite3()`)
- `Sources/BashPython/*`
  - `python3`, `python` alias (register via `BashSession.registerPython()` / `registerPython3()`)
  - runtime abstraction: `PythonRuntime`, default `PyodideRuntime`
- `Sources/BashGit/*`
  - `git` subset (register via `BashSession.registerGit()`)
  - runtime/interop: `GitEngine.swift` + `Clibgit2` SwiftPM binary target (`Clibgit2.xcframework`)

## Filesystem Architecture

Filesystem protocol:
- `Sources/Bash/FS/ShellFilesystem.swift`

Rootless-session protocol:
- `Sources/Bash/FS/SessionConfigurableFilesystem.swift`

Implementations:
- `Sources/Bash/FS/ReadWriteFilesystem.swift`
  - Real disk I/O with jail to configured root.
- `Sources/Bash/FS/InMemoryFilesystem.swift`
  - Pure in-memory tree.
- `Sources/Bash/FS/SandboxFilesystem.swift`
  - Root chooser (`documents`, `caches`, `temporary`, app group, custom URL), delegates to read-write backing.
- `Sources/Bash/FS/SecurityScopedFilesystem.swift`
  - Security-scoped URL/bookmark-backed root, optional read-only mode, runtime unsupported on tvOS/watchOS.

Bookmark persistence:
- `Sources/Bash/FS/BookmarkStore.swift`
- `Sources/Bash/FS/UserDefaultsBookmarkStore.swift`

Path + jail utilities:
- `Sources/Bash/Core/PathUtils.swift`

## Parser + Executor Source Map

- `Sources/Bash/Core/ShellLexer.swift`
- `Sources/Bash/Core/ShellParser.swift`
- `Sources/Bash/Core/ShellExecutor.swift`

Current shell language scope (implemented):
- Pipes: `|`
- Redirections: `>`, `>>`, `<`, `2>`, `2>&1`
- Chains: `&&`, `||`, `;`
- Variable expansion: `$VAR`, `${VAR}`, `${VAR:-default}`
- Globs: `*`, `?`, `[abc]` when enabled
- Path-like command invocation (`/bin/ls`, etc.)

Not in scope yet:
- shell control flow (`if`, `for`, `while`, functions, positional shell params)

## Testing Structure

All tests are Swift Testing suites:
- `Tests/BashTests/ParserAndFilesystemTests.swift`
- `Tests/BashTests/SessionIntegrationTests.swift`
- `Tests/BashTests/CommandCoverageTests.swift`
- `Tests/BashTests/FilesystemOptionsTests.swift`
- `Tests/BashTests/TestSupport.swift`
- `Tests/BashSQLiteTests/*`
- `Tests/BashPythonTests/*`
- `Tests/BashGitTests/*`

Coverage style:
- parser/lexer unit behavior
- filesystem safety and platform behavior
- command integration flows
- `--help` and invalid-flag coverage for built-ins

Run:
- `swift test`

## Parity Tracking

Command parity gaps vs `just-bash` are tracked in:
- `docs/command-parity-gaps.md`

When you add or upgrade command behavior:
1. Update the relevant command entry in `docs/command-parity-gaps.md`.
2. Lower the command priority only after tests are added for the newly closed gap.

## Contributor Rules of Thumb

When adding or changing a command:
1. Place it in the correct file family above (or create a new focused file if needed).
2. Keep command implementation in-process; do not shell out to host binaries.
3. Use `ParsableArguments` options so `--help` works automatically.
4. Return shell-like exit codes (`0` success, non-zero for command failure, `2` for usage/parser-style errors where appropriate).
5. Resolve paths through `CommandContext.resolvePath` and filesystem APIs; do not bypass jail semantics.
6. Preserve `stdin`/`stdout`/`stderr` behavior for pipelines and redirections.
7. Add/adjust tests in `SessionIntegrationTests` and `CommandCoverageTests`.
8. Keep cross-platform compilation intact; prefer runtime `ShellError.unsupported(...)` over compile-time API breakage for platform-limited behavior.

When adding filesystem implementations:
1. Conform to `ShellFilesystem`.
2. Conform to `SessionConfigurableFilesystem` if rootless `BashSession(options:)` should be supported.
3. Keep path normalization and jail guarantees explicit and tested.
4. Add platform-conditional tests in `FilesystemOptionsTests`.

## Command Registry Update Checklist

If you add a new built-in command:
1. Add the command type to `defaults` in `Sources/Bash/Commands/DefaultCommands.swift`.
2. Add it to the coverage list in `Tests/BashTests/CommandCoverageTests.swift`.
3. Add integration tests for at least one success and one failure/edge case.
4. Ensure `--help` output works and invalid flag behavior is non-zero.
