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
    public init(options: SessionOptions = .init()) async throws
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
- `filesystem`: `ReadWriteFilesystem()`
- `layout`: `.unixLike`
- `initialEnvironment`: `[:]`
- `enableGlobbing`: `true`
- `maxHistory`: `1000`

Available filesystem implementations:
- `ReadWriteFilesystem`: root-jail wrapper over real disk I/O.
- `InMemoryFilesystem`: fully in-memory filesystem with no disk writes.
- `SandboxFilesystem`: resolves app container-style roots (`documents`, `caches`, `temporary`, app group, custom URL).
- `SecurityScopedFilesystem`: URL/bookmark-backed filesystem for security-scoped access.

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

Built-in filesystem options:
- `ReadWriteFilesystem` (default): rooted at your `rootDirectory`; reads/writes hit disk in that sandboxed root.
- `InMemoryFilesystem`: virtual tree stored in memory; no file mutations are written to disk.
- `SandboxFilesystem`: root resolved from container locations, then backed by `ReadWriteFilesystem`.
- `SecurityScopedFilesystem`: root resolved from security-scoped URL or bookmark, then backed by `ReadWriteFilesystem`.

Behavior guarantees:
- All operations are scoped under the filesystem root.
- For `ReadWriteFilesystem`, symlink escapes outside root are blocked.
- Built-in command stubs are created under `/bin` and `/usr/bin` inside the selected filesystem.
- Unsupported platform features are surfaced as runtime `ShellError.unsupported(...)`, while all current package targets still compile.

Rootless session init example:

```swift
let inMemory = SessionOptions(filesystem: InMemoryFilesystem())
let session = try await BashSession(options: inMemory)
```

`BashSession.init(options:)` works with filesystems that can self-configure for a session (`SessionConfigurableFilesystem`), such as `InMemoryFilesystem`, `SandboxFilesystem`, and `SecurityScopedFilesystem`.

You can provide a custom filesystem by implementing `ShellFilesystem`.

### Filesystem Platform Matrix

| Filesystem | macOS | iOS | Catalyst | tvOS/watchOS |
| --- | --- | --- | --- | --- |
| `ReadWriteFilesystem` | supported | supported | supported | supported |
| `InMemoryFilesystem` | supported | supported | supported | supported |
| `SandboxFilesystem` | supported (where root resolves) | supported (where root resolves) | supported (where root resolves) | supported (where root resolves) |
| `SecurityScopedFilesystem` | supported | supported | supported | compiles; throws `ShellError.unsupported` when configured |

### Security-Scoped Bookmark Flow

```swift
let store = UserDefaultsBookmarkStore()

// Create from a URL chosen by your app's document flow.
let fs = try SecurityScopedFilesystem(url: pickedURL, mode: .readWrite)
try fs.configureForSession()
try await fs.saveBookmark(id: "workspace", store: store)

// Restore on a later app launch.
let restored = try await SecurityScopedFilesystem.loadBookmark(
    id: "workspace",
    store: store,
    mode: .readWrite
)

let session = try await BashSession(
    options: SessionOptions(filesystem: restored, layout: .rootOnly)
)
```

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
| `chmod` | `<mode> <paths...>`, `-R`, `--recursive` (octal mode only) |
| `file` | positional paths |
| `tree` | optional path, `-a`, `-L <level>` |

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
| `printf` | format string + positional values (`%s`, `%d`, `%i`, `%f`, `%%`) |
| `base64` | encode by default; `-d`, `--decode` |
| `sha256sum` | optional files (or stdin) |
| `sha1sum` | optional files (or stdin) |
| `md5sum` | optional files (or stdin) |

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
| `hostname` | none |
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
| `time` | `time <command...>` |
| `timeout` | `timeout <seconds> <command...>` |
| `true` | none |
| `whoami` | none |
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
1. `diff`
2. `rg`
3. `awk`
4. `sed`

### Deferred for later milestones
- `jq`, `yq`, `xan`, `sqlite3`, `python`, `python3`
- `gzip`, `gunzip`, `zcat`, `tar`
- `curl`, `html-to-markdown`
- `awk`, `sed`, `xargs`
