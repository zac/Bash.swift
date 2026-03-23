# Bash.swift

`Bash.swift` is an in-process, stateful shell for Swift apps. It is inspired by [just-bash](https://github.com/vercel-labs/just-bash). Commands runs inside Swift instead of spawning host shell processes.

You create a `BashSession`, run shell command strings, and get structured `stdout`, `stderr`, and `exitCode` results back. Session state persists across runs, including the working directory, environment, history, and registered built-ins.

`Bash.swift` should be treated as beta software. It is practical for app and agent workflows, but it is not a hardened isolation boundary and it is not a drop-in replacement for a real system shell. APIs are being actively experimented with and deployed. Ensure you lock to a specific commit or version tag if you plan to do any work utilizing this library.

## Why

`Bash.swift` is built for app and agent workflows that need shell-like behavior without subprocess management.

It provides:
- Stateful shell sessions (`cd`, `export`, `history`, shell functions)
- Real filesystem side effects under a controlled root
- In-process built-in commands implemented in Swift
- Practical shell syntax support for pipelines, redirection, chaining, background jobs, and simple scripting

## Installation

Add `Bash` with SwiftPM:

```swift
// Package.swift
.dependencies: [
    .package(url: "https://github.com/velos/Bash.swift.git", from: "0.1.0")
],
.targets: [
    .target(
        name: "YourTarget",
        dependencies: ["Bash"]
    )
]
```

Optional products:

```swift
dependencies: ["Bash", "BashSQLite", "BashPython", "BashGit", "BashSecrets"]
```

Notes:
- `Bash.swift` now depends on a separate `Workspace` package for the reusable filesystem layer.
- `Bash` reexports the Workspace filesystem types, so callers can use `FileSystem`, `WorkspacePath`, `ReadWriteFilesystem`, `InMemoryFilesystem`, `OverlayFilesystem`, `MountableFilesystem`, `SandboxFilesystem`, and `SecurityScopedFilesystem` directly from `Bash`.
- `BashPython` uses a prebuilt `CPython.xcframework` binary target.
- `BashGit` uses a prebuilt `Clibgit2.xcframework` binary target.

Supported package platforms:
- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+

## Quick Start

```swift
import Bash
import Foundation

let root = URL(fileURLWithPath: "/tmp/bash-session", isDirectory: true)
let session = try await BashSession(rootDirectory: root)

_ = await session.run("touch file.txt")
let ls = await session.run("ls")
print(ls.stdoutString) // file.txt

let piped = await session.run("echo hello | tee out.txt > copy.txt")
print(piped.exitCode) // 0
```

For isolated per-run overrides without mutating the session's persisted shell state:

```swift
let scoped = await session.run(
    "pwd && echo $MODE",
    options: RunOptions(
        environment: ["MODE": "preview"],
        currentDirectory: "/tmp"
    )
)
```

## Optional Modules

Optional command sets must be registered at runtime.

`BashSQLite`:

```swift
import BashSQLite

await session.registerSQLite3()
let result = await session.run("sqlite3 :memory: \"select 1;\"")
print(result.stdoutString) // 1
```

`BashPython`:

```swift
import BashPython

await BashPython.setCPythonRuntime()
await session.registerPython()
let py = await session.run("python3 -c \"print('hi')\"")
print(py.stdoutString) // hi
```

`BashPython` embeds CPython directly. The current prebuilt runtime is available on macOS. Other Apple platforms still compile, but runtime execution returns unavailable errors. Filesystem access stays inside the shell's configured `FileSystem`, and escape APIs such as `subprocess`, `ctypes`, and `os.system` are intentionally blocked. Maintainer notes for the broader Apple runtime plan live in [docs/cpython-apple-runtime.md](docs/cpython-apple-runtime.md).

`BashGit`:

```swift
import BashGit

await session.registerGit()
_ = await session.run("git init")
```

`BashSecrets`:

```swift
import BashSecrets

let provider = AppleKeychainSecretsProvider()
await session.registerSecrets(provider: provider)
let ref = await session.run(
    "secrets put --service app --account api",
    stdin: Data("token".utf8)
)
```

`BashSecrets` uses provider-owned opaque `secretref:...` references. `secrets get --reveal` is explicit, and `.resolveAndRedact` or `.strict` policies keep plaintext out of caller-visible output by default.

## Workspace Package

`Bash` sits on top of a reusable `Workspace` package. If you only need filesystem and workspace tooling, use `Workspace` directly instead of `BashSession`.

Example:

```swift
import Workspace

let filesystem = PermissionedFileSystem(
    base: try OverlayFilesystem(rootDirectory: workspaceRoot),
    authorizer: PermissionAuthorizer { request in
        switch request.operation {
        case .readFile, .listDirectory, .stat:
            return .allowForSession
        default:
            return .deny(message: "write access denied")
        }
    }
)

let workspace = Workspace(filesystem: filesystem)
let tree = try await workspace.summarizeTree("/workspace", maxDepth: 2)
```

## API Summary

Primary entry point:

```swift
public final actor BashSession {
    public init(rootDirectory: URL, options: SessionOptions = .init()) async throws
    public init(options: SessionOptions = .init()) async throws
    public func run(_ commandLine: String, stdin: Data = Data()) async -> CommandResult
    public func run(_ commandLine: String, options: RunOptions) async -> CommandResult
    public func register(_ command: any BuiltinCommand.Type) async
}
```

High-level types:
- `CommandResult`: `stdout`, `stderr`, `exitCode`, plus string helpers
- `RunOptions`: per-run `stdin`, environment overrides, temporary `cwd`, execution limits, and cancellation probe
- `ExecutionLimits`: caps command count, function depth, loop iterations, command substitution depth, and optional wall-clock duration
- `SessionOptions`: filesystem, layout, initial environment, globbing, history length, network policy, execution limits, permission callback, and secret policy
- `ShellPermissionRequest` / `ShellPermissionDecision`: shell-facing permission callback types
- `ShellNetworkPolicy`: built-in outbound network policy

Practical behavior:
- `BashSession.init` can throw during setup
- `run` always returns a `CommandResult`, including parser/runtime faults
- Unknown commands return exit code `127`
- Parser/runtime faults use exit code `2`
- `maxWallClockDuration` failures use exit code `124`
- Cancellation uses exit code `130`

## Security Model

`Bash.swift` is a practical execution environment, not a hardened sandbox.

Current hardening layers include:
- Root-jail filesystem implementations plus null-byte path rejection
- Optional permission callbacks for filesystem and network access
- `ShellNetworkPolicy` with default-off HTTP(S), host allowlists, URL-prefix allowlists, and private-range blocking
- Execution budgets through `ExecutionLimits`
- Strict `BashPython` shims that block process and FFI escape APIs
- Secret-reference resolution and redaction policies

Important notes:
- Outbound HTTP(S) is disabled by default
- `permissionHandler` applies after the built-in network policy passes
- Permission wait time is excluded from `timeout` and run-level wall-clock accounting
- `curl` / `wget`, `git clone`, and `BashPython` socket connections share the same network policy path
- `data:` URLs and jailed `file:` URLs do not trigger outbound network checks

## Filesystem Model

Filesystems available via [Workspace](https://github.com/velos/Workspace):
- `ReadWriteFilesystem`: rooted real disk I/O
- `InMemoryFilesystem`: fully in-memory tree
- `OverlayFilesystem`: snapshots an on-disk root into memory; later writes stay in memory
- `MountableFilesystem`: composes multiple filesystems under virtual mount points
- `SandboxFilesystem`: container-root chooser (`documents`, `caches`, `temporary`, app group, custom URL)
- `SecurityScopedFilesystem`: security-scoped URL or bookmark-backed root

Behavior guarantees:
- All shell-visible paths are scoped to the configured filesystem root
- `ReadWriteFilesystem` blocks symlink escapes outside the root
- Filesystem implementations reject paths containing null bytes
- Built-in command stubs are created under `/bin` and `/usr/bin` for unix-like layouts
- Unsupported platform features surface as runtime unsupported errors from `Bash` or `Workspace`

Rootless session example:

```swift
let options = SessionOptions(filesystem: InMemoryFilesystem(), layout: .unixLike)
let session = try await BashSession(options: options)
```

## Shell Scope

Supported shell features include:
- Quoting and escaping
- Pipes
- Redirections: `>`, `>>`, `<`, `<<`, `<<-`, `2>`, `2>&1`
- Chaining: `&&`, `||`, `;`
- Background execution with `jobs`, `fg`, `wait`, `ps`, `kill`
- Command substitution: `$(...)`
- Variables and default expansion: `$VAR`, `${VAR}`, `${VAR:-default}`, `$!`
- Globbing
- Here-documents
- Functions and `local`
- `if` / `elif` / `else`
- `while`, `until`, `for ... in ...`, and C-style `for ((...))`
- Path-like command invocation such as `/bin/ls`

Not supported:
- A full bash or POSIX shell grammar
- Host subprocess execution for ordinary commands
- Full TTY semantics or real OS job control
- Many advanced bash compatibility edge cases

## Commands

All built-ins support `--help`, and most also support `-h`.

Core built-in coverage includes:
- File operations: `cat`, `cp`, `ln`, `ls`, `mkdir`, `mv`, `readlink`, `rm`, `rmdir`, `stat`, `touch`, `chmod`, `file`, `tree`, `diff`
- Text processing: `grep`, `rg`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`, `awk`, `sed`, `xargs`, `printf`, `base64`, `sha256sum`, `sha1sum`, `md5sum`
- Data tools: `jq`, `yq`, `xan`
- Compression and archives: `gzip`, `gunzip`, `zcat`, `zip`, `unzip`, `tar`
- Navigation and environment: `basename`, `cd`, `dirname`, `du`, `echo`, `env`, `export`, `find`, `printenv`, `pwd`, `tee`
- Utilities: `clear`, `date`, `false`, `fg`, `help`, `history`, `jobs`, `kill`, `ps`, `seq`, `sleep`, `time`, `timeout`, `true`, `wait`, `whoami`, `which`
- Network commands: `curl`, `wget`, `html-to-markdown`

Optional command sets:
- `sqlite3` via `BashSQLite`
- `python3` / `python` via `BashPython`
- `git` via `BashGit`
- `secrets` / `secret` via `BashSecrets`

## Testing

Run the test suite with:

```bash
swift test
```

The repository includes parser, filesystem, integration, command coverage, and optional-module tests.
