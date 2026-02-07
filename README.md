# BashSwift

`BashSwift` provides an in-process, stateful, emulated shell for Swift apps.

You create a `BashSession`, run shell command strings, and get structured `stdout` / `stderr` / `exitCode` results. Commands mutate a real directory on disk through a sandboxed, root-jail filesystem abstraction.

## Why

`BashSwift` is aimed at practical shell behavior you can use from app code and tests:
- Stateful shell session (`cd`, `export`, `history` persist across `run` calls)
- Real filesystem side effects under a controlled root directory
- Built-in fake CLIs implemented in Swift (no subprocess dependency)
- Shell parsing/execution features needed for scripts (`|`, redirection, `&&`, `||`, `;`)

## Installation

### Swift Package Manager (local package)

```swift
// Package.swift
.dependencies: [
    .package(path: "../Bash.swift")
],
.targets: [
    .target(
        name: "YourTarget",
        dependencies: ["BashSwift"]
    )
]
```

## Platform Support

Current package platforms:
- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+

## Quick Start

```swift
import BashSwift
import Foundation

let root = URL(fileURLWithPath: "/tmp/bashswift-session", isDirectory: true)
let session = try await BashSession(rootDirectory: root)

_ = await session.run("touch file.txt")
let ls = await session.run("ls")
print(ls.stdoutString) // file.txt

let piped = await session.run("echo hello | tee out.txt > copy.txt")
print(piped.exitCode) // 0
```

## Public API

### `BashSession`

```swift
public final actor BashSession {
    public init(rootDirectory: URL, options: SessionOptions = .init()) async throws
    public func run(_ commandLine: String, stdin: Data = Data()) async -> CommandResult
    public func register(_ command: any BuiltinCommand.Type) async
    public var currentDirectory: String { get async }
    public var environment: [String: String] { get async }
}
```

### `CommandResult`

```swift
public struct CommandResult {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32

    public var stdoutString: String { get }
    public var stderrString: String { get }
}
```

### `SessionOptions`

```swift
public struct SessionOptions {
    public var filesystem: any ShellFilesystem
    public var layout: SessionLayout
    public var initialEnvironment: [String: String]
    public var enableGlobbing: Bool
    public var maxHistory: Int
}
```

Defaults:
- `filesystem`: `RealFilesystem()`
- `layout`: `.unixLike`
- `initialEnvironment`: `[:]`
- `enableGlobbing`: `true`
- `maxHistory`: `1000`

### `SessionLayout`

- `.unixLike` (default): creates `/home/user`, `/bin`, `/usr/bin`, `/tmp`; starts in `/home/user`
- `.rootOnly`: minimal root-only layout

## How It Works

Execution pipeline:
1. Command line is lexed/parses into a shell AST.
2. Variables/globs are expanded.
3. Pipelines/chains execute against registered in-process built-ins.
4. The session state is updated (`cwd`, environment, history).
5. `CommandResult` is returned.

### Supported Shell Features

- Quoting and escaping (`'...'`, `"..."`, `\\`)
- Pipes: `cmd1 | cmd2`
- Redirections: `>`, `>>`, `<`, `2>`, `2>&1`
- Command chaining: `&&`, `||`, `;`
- Variables: `$VAR`, `${VAR}`, `${VAR:-default}`
- Globs: `*`, `?`, `[abc]` (when `enableGlobbing` is true)
- Command lookup by name and by path-like invocation (`/bin/ls`)

### Not Yet Supported (Shell Language)

- Positional parameters (`$1`, `$@`, etc.)
- `if/then/elif/else/fi`
- `for/while/until`
- Shell functions and `local`

## Filesystem Model

`RealFilesystem` is rooted at your provided `rootDirectory` and enforces path jail behavior:
- All operations are scoped under the root
- Symlink escapes outside root are blocked
- Built-in command stubs are created under `/bin` and `/usr/bin` for command lookup behavior

You can provide a custom filesystem by implementing `ShellFilesystem`.

## Implemented Commands

All implemented commands support `--help`.

### File Operations

| Command | Supported Options |
| --- | --- |
| `cat` | positional files |
| `cp` | `-R`, `--recursive` |
| `ln` | `-s`, `--symbolic` |
| `ls` | `-l`, `-a` |
| `mkdir` | `-p` |
| `mv` | positional source/destination |
| `readlink` | positional path |
| `rm` | `-r`, `-R`, `-f` |
| `rmdir` | positional paths |
| `stat` | positional paths |
| `touch` | positional paths |

### Text Processing

| Command | Supported Options |
| --- | --- |
| `grep` | `-i`, `-v`, `-n` (`egrep`, `fgrep` aliases) |
| `head` | `-n`, `--n` |
| `tail` | `-n`, `--n` |
| `wc` | `-l`, `-w`, `-c` |
| `sort` | `-r` |
| `uniq` | `-c` |
| `cut` | `-d <delimiter>`, `-f <fields>` |
| `tr` | positional source/destination char sets |

### Navigation & Environment

| Command | Supported Options |
| --- | --- |
| `basename` | positional paths |
| `cd` | optional positional path |
| `dirname` | positional paths |
| `du` | `-s` |
| `echo` | `-n` |
| `env` | none |
| `export` | positional `KEY=VALUE` assignments |
| `find` | `--name <pattern>`, optional path |
| `printenv` | optional positional keys |
| `pwd` | none |
| `tee` | `-a` |

### Shell Utilities

| Command | Supported Options |
| --- | --- |
| `clear` | none |
| `date` | `-u` |
| `false` | none |
| `help` | none |
| `history` | `-n`, `--n` |
| `seq` | positional number args |
| `sleep` | positional seconds |
| `true` | none |
| `which` | positional command names |

## Command Behaviors and Notes

- Unknown commands return exit code `127` and write `command not found` to `stderr`.
- Non-zero command exits are returned in `CommandResult.exitCode` (not thrown).
- `BashSession.init` can throw; `run` always returns `CommandResult` (including parser/runtime failures as non-zero exits).
- Pipelines are currently sequential and buffered (`stdout` from one command becomes `stdin` for the next command).

## Testing

```bash
swift test
```

The project currently includes parser, filesystem, integration, and command coverage tests.

## Roadmap

### Priority (next)
1. `printf`
2. `base64`
3. `sha256sum`, `sha1sum`, `md5sum`
4. `chmod`
5. `file`
6. `tree`
7. `hostname`, `whoami`
8. `time`, `timeout`

### After that
1. `diff`
2. `rg`

### Deferred for later milestones
- `jq`, `yq`, `xan`, `sqlite3`, `python`, `python3`
- `gzip`, `gunzip`, `zcat`, `tar`
- `curl`, `html-to-markdown`
- `awk`, `sed`, `xargs`
