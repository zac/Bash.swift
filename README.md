# Bash.swift

`Bash.swift` provides an in-process, stateful, emulated shell for Swift apps. It's heavily inspired by [just-bash](https://github.com/vercel-labs/just-bash).

Repository: [github.com/velos/Bash.swift](https://github.com/velos/Bash.swift)

You create a `BashSession`, run shell command strings, and get structured `stdout` / `stderr` / `exitCode` results. Commands mutate a real directory on disk through a sandboxed, root-jail filesystem abstraction.

Like `just-bash`, `Bash.swift` should be treated as beta software and used at your own risk. The library is practical for app and agent workflows, but it is still evolving and should not be treated as a hardened isolation boundary or a drop-in replacement for a real system shell.

## Development Process

Development of `Bash.swift` was approached very similarly to [just-bash](https://github.com/vercel-labs/just-bash). All output was with GPT-5.3-Codex Extra High thinking, initiated by an interactively built plan, executed by the model after the plan was finalized.

## Contents

- [Why](#why)
- [Installation](#installation)
- [Platform Support](#platform-support)
- [Quick Start](#quick-start)
- [Workspace Modules](#workspace-modules)
- [Public API](#public-api)
- [How It Works](#how-it-works)
- [Security](#security)
- [Filesystem Model](#filesystem-model)
- [Implemented Commands](#implemented-commands)
- [Eval Runner and Profiles](#eval-runner-and-profiles)
- [Testing](#testing)
- [Roadmap](#roadmap)

## Why

`Bash.swift` is aimed at providing a tool for use in agents. Leveraging the approach that "Bash is all you need". To enable this use-case, it provides:
- Stateful shell session (`cd`, `export`, `history` persist across `run` calls)
- Real filesystem side effects under a controlled root directory
- Built-in fake CLIs implemented in Swift (no subprocess dependency)
- Shell parsing/execution features needed for scripts (`|`, redirection, `&&`, `||`, `;`, `&`)

## Installation

### Swift Package Manager (remote package)

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

The reusable shell-agnostic workspace layer now lives in a separate `Workspace` package/repository. `Bash.swift` depends on that package, but it is no longer shipped as part of this repo.

`BashSQLite`, `BashPython`, `BashGit`, and `BashSecrets` are optional products. Add them only if needed:

```swift
dependencies: ["Bash", "BashSQLite", "BashPython", "BashGit", "BashSecrets"]
```

`BashPython` uses a remote `CPython.xcframework` binary target hosted in the repo's GitHub Releases, so consumers do not
need Git LFS and the prebuilt CPython framework is not checked into the repository.

If you include optional products, remember to register their commands at runtime (`registerSQLite3`, `registerPython`, `registerGit`, `registerSecrets`).

## Platform Support

Current package platforms:
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

For isolated one-off overrides without mutating the session's persisted `cwd` or environment:

```swift
let scoped = await session.run(
    "pwd && echo $MODE",
    options: RunOptions(
        environment: ["MODE": "preview"],
        currentDirectory: "/tmp"
    )
)
print(scoped.stdoutString)
```

Optional `sqlite3` registration:

```swift
import BashSQLite

await session.registerSQLite3()
let sql = await session.run("sqlite3 :memory: \"select 1;\"")
print(sql.stdoutString) // 1
```

Optional `python3` / `python` registration:

```swift
import BashPython

await BashPython.setCPythonRuntime() // Optional: defaults to strict filesystem shims.
await session.registerPython()

let py = await session.run("python3 -c \"print('hi')\"")
print(py.stdoutString) // hi
```

`BashPython` embeds CPython directly (no JavaScriptCore/Pyodide path). The current prebuilt CPython runtime is available on macOS.
On other Apple platforms, including iOS/iPadOS, Mac Catalyst, tvOS, and watchOS, the module still compiles but runtime execution returns an unavailable error.
Maintainer notes for the broader Apple runtime plan live in [`docs/cpython-apple-runtime.md`](docs/cpython-apple-runtime.md).

Strict filesystem mode is enabled by default. Script-visible file APIs are shimmed through `ShellFilesystem`, so Python file operations share the same jailed root as shell commands.
Blocked escape APIs include `subprocess`, `ctypes`, and process-spawn helpers like `os.system` / `os.popen` / `os.spawn*`.
`SessionOptions.networkPolicy` and `permissionHandler` also apply to Python socket connections, so host apps can enforce the same outbound rules across shell commands and embedded Python.
`pip` and arbitrary native extension loading are non-goals in this runtime profile.

Optional `git` registration:

```swift
import BashGit

await session.registerGit()
_ = await session.run("git init")
_ = await session.run("git add -A")
let commit = await session.run("git commit -m \"Initial commit\"")
print(commit.exitCode)
```

`BashGit` uses a prebuilt `Clibgit2.xcframework` binary target (iOS, iOS Simulator, macOS, Catalyst). The binary artifact is fetched by SwiftPM during dependency resolution.

Optional `secrets` registration:

```swift
import BashSecrets

await session.registerSecrets()
let ref = await session.run("secrets put --service app --account api", stdin: Data("token".utf8))
let use = await session.run("secrets run --env API_TOKEN=\(ref.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) -- printenv API_TOKEN")
print(use.stdoutString)
```

`BashSecrets` defaults to Apple Keychain generic-password storage through Security.framework and emits opaque `secretref:v1:...` references.

For harness/tooling flows where the model should only handle references, use the `Secrets` API directly:

```swift
let ref = try await Secrets.putGenericPassword(
    service: "app",
    account: "api",
    value: Data("token".utf8)
)

// Resolve inside trusted tool code, not in model-visible shell output.
let secretValue = try await Secrets.resolveReference(ref)
```

For secret-aware command execution/redaction inside `BashSession`, configure a resolver and policy:

```swift
let options = SessionOptions(
    filesystem: ReadWriteFilesystem(),
    layout: .unixLike,
    secretPolicy: .strict,
    secretResolver: BashSecretsReferenceResolver()
)
let session = try await BashSession(rootDirectory: root, options: options)
```

Policies:
- `.off`: no automatic secret-reference resolution/redaction in builtins
- `.resolveAndRedact`: resolve refs (where supported) and redact/replace secrets in output
- `.strict`: like `.resolveAndRedact`, plus blocks high-risk flows like `secrets get --reveal`

## Workspace Modules

`Bash` now sits on top of reusable workspace primitives provided by a separate `Workspace` package:

- `Workspace`: a typed agent-facing API plus the shell-agnostic filesystem abstractions, jailed/rooted filesystem implementations, overlays, mounts, bookmarks, path helpers, and filesystem permission wrappers it is built on.

Import `Workspace` from that package directly when you want workspace tooling without shell parsing or command execution:

```swift
import Workspace

let filesystem = PermissionedWorkspaceFilesystem(
    base: try OverlayFilesystem(rootDirectory: workspaceRoot),
    authorizer: WorkspacePermissionAuthorizer { request in
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

`replaceInFiles` and `applyEdits` support dry runs plus best-effort rollback on failure. That rollback is logical state restoration within the provided filesystem, not an OS-level atomic transaction and not crash-safe across processes.

## Public API

### `BashSession`

```swift
public final actor BashSession {
    public init(rootDirectory: URL, options: SessionOptions = .init()) async throws
    public init(options: SessionOptions = .init()) async throws
    public func run(_ commandLine: String, stdin: Data = Data()) async -> CommandResult
    public func run(_ commandLine: String, options: RunOptions) async -> CommandResult
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

### `RunOptions`

```swift
public struct RunOptions {
    public var stdin: Data
    public var environment: [String: String]
    public var replaceEnvironment: Bool
    public var currentDirectory: String?
    public var executionLimits: ExecutionLimits?
    public var cancellationCheck: (@Sendable () -> Bool)?
}
```

Use `RunOptions` when you want a Cloudflare-style per-execution override without changing the session's persisted shell state. Filesystem mutations still persist; environment, working-directory, and function changes from that run do not. You can also tighten execution budgets or provide a host cancellation probe for a single run.

### `ExecutionLimits`

```swift
public struct ExecutionLimits {
    public static let `default`: ExecutionLimits

    public var maxCommandCount: Int
    public var maxFunctionDepth: Int
    public var maxLoopIterations: Int
    public var maxCommandSubstitutionDepth: Int
    public var maxWallClockDuration: TimeInterval?
}
```

Each `run` executes under an `ExecutionLimits` budget. Exceeding a structural limit stops execution with exit code `2`. If `maxWallClockDuration` is exceeded, execution stops with exit code `124`. If `cancellationCheck` returns `true`, or the surrounding task is cancelled, execution stops with exit code `130`. Wall-clock accounting excludes time spent waiting on host permission callbacks.

### `PermissionRequest` and `PermissionDecision`

```swift
public struct PermissionRequest {
    public enum Kind {
        case network(NetworkPermissionRequest)
        case filesystem(FilesystemPermissionRequest)
    }

    public var command: String
    public var kind: Kind
}

public struct NetworkPermissionRequest {
    public var url: String
    public var method: String
}

public enum FilesystemPermissionOperation: String {
    case stat
    case listDirectory
    case readFile
    case writeFile
    case createDirectory
    case remove
    case move
    case copy
    case createSymlink
    case createHardLink
    case readSymlink
    case setPermissions
    case resolveRealPath
    case exists
    case glob
}

public struct FilesystemPermissionRequest {
    public var operation: FilesystemPermissionOperation
    public var path: String?
    public var sourcePath: String?
    public var destinationPath: String?
    public var append: Bool
    public var recursive: Bool
}

public enum PermissionDecision {
    case allow
    case allowForSession
    case deny(message: String?)
}
```

### `NetworkPolicy`

```swift
public struct NetworkPolicy {
    public static let disabled: NetworkPolicy
    public static let unrestricted: NetworkPolicy

    public var allowsHTTPRequests: Bool
    public var allowedHosts: [String]
    public var allowedURLPrefixes: [String]
    public var denyPrivateRanges: Bool
}
```

Outbound HTTP(S) is disabled by default. Use `.unrestricted` or set `allowsHTTPRequests: true` to opt in. `allowedHosts` fits host-level allowlisting that should also apply to `git` remotes and Python socket connections. `allowedURLPrefixes` is stricter and is matched with exact scheme/host/port plus path-boundary validation for URL-aware tools like `curl` and `wget`. When an allowlist is present, a request must match the host list or the URL-prefix list before any private-range DNS checks run.

### `SessionOptions`

```swift
public struct SessionOptions {
    public var filesystem: any ShellFilesystem
    public var layout: SessionLayout
    public var initialEnvironment: [String: String]
    public var enableGlobbing: Bool
    public var maxHistory: Int
    public var networkPolicy: NetworkPolicy
    public var executionLimits: ExecutionLimits
    public var permissionHandler: (@Sendable (PermissionRequest) async -> PermissionDecision)?
    public var secretPolicy: SecretHandlingPolicy
    public var secretResolver: (any SecretReferenceResolving)?
    public var secretOutputRedactor: any SecretOutputRedacting
}
```

Defaults:
- `filesystem`: `ReadWriteFilesystem()`
- `layout`: `.unixLike`
- `initialEnvironment`: `[:]`
- `enableGlobbing`: `true`
- `maxHistory`: `1000`
- `networkPolicy`: `NetworkPolicy.disabled`
- `executionLimits`: `ExecutionLimits.default`
- `permissionHandler`: `nil`
- `secretPolicy`: `.off`
- `secretResolver`: `nil`
- `secretOutputRedactor`: `DefaultSecretOutputRedactor()`

Use `networkPolicy` for built-in outbound rules such as default-off HTTP(S), private-range blocking, and allowlists. Use `executionLimits` to bound shell work at the session level. Use `permissionHandler` when the host app or agent needs explicit control over filesystem and outbound network access after the built-in policy passes. Returning `.allow` grants the current request once, `.allowForSession` caches an exact-match request for the life of that `BashSession`, and `.deny(message:)` blocks it with a user-visible error. If you want broader or persistent memory across sessions, keep that policy in the host and decide what to return from the callback.

Example built-in policy plus callback:

```swift
let options = SessionOptions(
    networkPolicy: NetworkPolicy(
        allowsHTTPRequests: true,
        allowedHosts: ["api.example.com"],
        allowedURLPrefixes: ["https://api.example.com/v1/"],
        denyPrivateRanges: true
    ),
    permissionHandler: { request in
        switch request.kind {
        case let .network(network):
            if network.url.hasPrefix("https://api.example.com/v1/") {
                return .allowForSession
            }
            return .deny(message: "network access denied")
        case let .filesystem(filesystem):
            switch filesystem.operation {
            case .readFile, .listDirectory, .stat:
                return .allowForSession
            default:
                return .deny(message: "filesystem access denied")
            }
        }
    }
)
```

Available filesystem implementations:
- `ReadWriteFilesystem`: root-jail wrapper over real disk I/O.
- `InMemoryFilesystem`: fully in-memory filesystem with no disk writes.
- `OverlayFilesystem`: snapshots an on-disk root into an in-memory overlay for the session; later writes stay in memory.
- `MountableFilesystem`: composes multiple filesystems under virtual mount points like `/workspace` and `/docs`.
- `SandboxFilesystem`: resolves app container-style roots (`documents`, `caches`, `temporary`, app group, custom URL).
- `SecurityScopedFilesystem`: URL/bookmark-backed filesystem for security-scoped access.

For non-shell agent tooling, `Workspace` exposes the same filesystem stack under shell-agnostic names like `WorkspaceFilesystem`, `WorkspacePath`, `WorkspaceError`, and `PermissionedWorkspaceFilesystem`, along with the higher-level `Workspace` actor for typed tree traversal and batch editing helpers. A single `Workspace` can also sit on top of a `MountableFilesystem`, so isolated roots plus a shared `/memory` mount are already possible through the current interfaces.

### `SessionLayout`

- `.unixLike` (default): creates `/home/user`, `/bin`, `/usr/bin`, `/tmp`; starts in `/home/user`
- `.rootOnly`: minimal root-only layout

## How It Works

Execution pipeline:
1. Command line is lexed and parsed into a shell AST.
2. Variables/globs are expanded.
3. Pipelines/chains execute against registered in-process built-ins.
4. The session state is updated (`cwd`, environment, history).
5. `CommandResult` is returned.

`run(_:options:)` follows the same pipeline, but starts from temporary environment / cwd overrides and restores the session shell state afterward.

## Security

`Bash.swift` is a practical execution environment, not a hardened security sandbox. The project is designed to keep command execution in-process, jail filesystem access to the configured root, and give the embedding app explicit control over sensitive surfaces such as secrets and outbound network access. That said, it should be treated as defense-in-depth for app and agent workflows, not as a guarantee that hostile code is safely contained.

Current hardening layers include:
- Root-jail filesystem implementations plus null-byte path rejection.
- Reusable workspace-level permission wrappers (`PermissionedWorkspaceFilesystem`) that can gate reads, writes, moves, copies, symlinks, and metadata operations before they hit the underlying filesystem.
- Optional `NetworkPolicy` rules with default-off HTTP(S), `denyPrivateRanges`, host allowlists, URL-prefix allowlists, and the host `permissionHandler`.
- Built-in execution budgets for command count, loop iterations, function depth, and command substitution depth, plus host-driven cancellation.
- Strict `BashPython` shims that block process/FFI escape APIs like `subprocess`, `ctypes`, and `os.system`.
- Secret-reference resolution/redaction policies that keep opaque references in model-visible flows by default.

Security-sensitive embeddings should still assume the host app owns the real trust boundary. If you need durable user consent, domain reputation checks, persistent policy memory, stricter runtime isolation, or stronger resource limits, keep those controls in the host and use `BashSession` as one layer rather than the whole boundary.

### Supported Shell Features

- Quoting and escaping (`'...'`, `"..."`, `\\`)
- Pipes: `cmd1 | cmd2`
- Redirections: `>`, `>>`, `<`, `<<`, `<<-`, `2>`, `2>&1`
- Command chaining: `&&`, `||`, `;`
- Background execution: `&` with `jobs`, `fg`, `wait`
- Command substitution: `$(...)` (including nested forms)
- Simple `for` loops: `for name in values; do ...; done` (supports trailing redirections)
- Simple control flow: `if ... then ... else ... fi`, `while ...; do ...; done`
- Shell functions: `name(){ ...; }` definitions and invocation (persist across `run` calls)
- Variables: `$VAR`, `${VAR}`, `${VAR:-default}`, `$!` (last background pseudo-PID)
- Globs: `*`, `?`, `[abc]` (when `enableGlobbing` is true)
- Command lookup by name and by path-like invocation (`/bin/ls`)

### Not Yet Supported (Shell Language)

- Full positional-parameter semantics (`$0`, `$*`, quoted `$@` parity edge-cases)
- `if/then/elif/else/fi` advanced forms (`elif`, nested branches parity)
- `until`
- Full `for` loop surface (`for ...; do` newline form, omitted `in` list, C-style `for ((...))`)
- Function features like `local`, `return`, and `function name { ... }` syntax
- Full POSIX job-control signals/states (`bg`, `disown`, signal forwarding)

## Filesystem Model

Built-in filesystem options:
- `ReadWriteFilesystem` (default): rooted at your `rootDirectory`; reads/writes hit disk in that sandboxed root.
- `InMemoryFilesystem`: virtual tree stored in memory; no file mutations are written to disk.
- `OverlayFilesystem`: imports an on-disk root into memory at session start; later writes stay in memory and do not modify the host root.
- `MountableFilesystem`: routes different virtual path prefixes to different filesystem backends.
- `SandboxFilesystem`: root resolved from container locations, then backed by `ReadWriteFilesystem`.
- `SecurityScopedFilesystem`: root resolved from security-scoped URL or bookmark, then backed by `ReadWriteFilesystem`.

Behavior guarantees:
- All operations are scoped under the filesystem root.
- For `ReadWriteFilesystem`, symlink escapes outside root are blocked.
- Filesystem implementations reject paths containing null bytes.
- Built-in command stubs are created under `/bin` and `/usr/bin` inside the selected filesystem.
- Unsupported platform features are surfaced as runtime `ShellError.unsupported(...)`, while all current package targets still compile.

Rootless session init example:

```swift
let inMemory = SessionOptions(filesystem: InMemoryFilesystem())
let session = try await BashSession(options: inMemory)
```

`BashSession.init(options:)` uses the filesystem exactly as provided. Pass a ready-to-use filesystem instance. `InMemoryFilesystem` works immediately; root-backed filesystems should be constructed or configured with their root before being passed in.

You can provide a custom filesystem by implementing `ShellFilesystem`.

If you do not need shell semantics, use `WorkspaceFilesystem` and the higher-level `Workspace` actor directly. The underlying jail, overlay, mount, bookmark, and permission concepts are shared; the shell layer is optional.

### Filesystem Platform Matrix

| Filesystem | macOS | iOS | Catalyst | tvOS/watchOS |
| --- | --- | --- | --- | --- |
| `ReadWriteFilesystem` | supported | supported | supported | supported |
| `InMemoryFilesystem` | supported | supported | supported | supported |
| `OverlayFilesystem` | supported | supported | supported | supported |
| `MountableFilesystem` | supported | supported | supported | supported |
| `SandboxFilesystem` | supported (where root resolves) | supported (where root resolves) | supported (where root resolves) | supported (where root resolves) |
| `SecurityScopedFilesystem` | supported | supported | supported | compiles; throws `ShellError.unsupported` when configured |

### Security-Scoped Bookmark Flow

```swift
let store = UserDefaultsBookmarkStore()

// Create from a URL chosen by your app's document flow.
let fs = try SecurityScopedFilesystem(url: pickedURL, mode: .readWrite)
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
| `diff` | `<left> <right>` |

### Text Processing

| Command | Supported Options |
| --- | --- |
| `grep` | `-E`, `-F`, `-i`, `-v`, `-n`, `-c`, `-l`, `-L`, `-o`, `-w`, `-x`, `-r`, `-e <pattern>`, `-f <file>` (`egrep`, `fgrep` aliases) |
| `rg` | `-i`, `-S`, `-F`, `-n`, `-l`, `-c`, `-m <num>`, `-w`, `-x`, `-A/-B/-C`, `--hidden`, `--no-ignore`, `--files`, `-e <pattern>`, `-f <file>`, `-g/--glob`, `-t <type>`, `-T <type>` |
| `head` | `-n`, `--n`, `-c`, `-q`, `-v` |
| `tail` | `-n`, `--n` (supports `+N`), `-c`, `-q`, `-v` |
| `wc` | `-l`, `-w`, `-c`, `-m`, `--chars` |
| `sort` | `-r`, `-n`, `-u`, `-f`, `-c`, `-k <field>`, `-o <file>` |
| `uniq` | `-c`, `-d`, `-u`, `-i`; optional `[input [output]]` operands |
| `cut` | `-d <delimiter>`, `-f <list>`, `-c <list>`, `-s` (`list`: `N`, `N-M`, `-M`, `N-`) |
| `tr` | `-d`, `-s`, `-c`; supports escapes (`\\n`, `\\t`, `\\r`) and ranges (`a-z`) |
| `awk` | `-F <separator>`; supports `{print}`, `{print $N}`, `/regex/ {print ...}` |
| `sed` | substitution scripts only: `s/pattern/replacement/` and `s/.../.../g` |
| `xargs` | `-I <replace>`, `-d <delim>`, `-n <max-args>`, `-L/--max-lines <num>`, `-E/--eof <str>`, `-P <max-procs>`, `-0/--null`, `-t/--verbose`, `-r/--no-run-if-empty`; default command `echo` |
| `printf` | format string + positional values (`%s`, `%d`, `%i`, `%f`, `%%`) |
| `base64` | encode by default; `-d`, `--decode` |
| `sha256sum` | optional files (or stdin) |
| `sha1sum` | optional files (or stdin) |
| `md5sum` | optional files (or stdin) |

### Data Processing

| Command | Supported Options |
| --- | --- |
| `sqlite3` | **Opt-in via `BashSQLite`**: modes `-list`, `-csv`, `-json`, `-line`, `-column`, `-table`, `-markdown`; `-header`, `-noheader`, `-separator <sep>`, `-newline <nl>`, `-nullvalue <str>`, `-readonly`, `-bail`, `-cmd <sql>`, `-version`, `--`; syntax `sqlite3 [options] [database] [sql]` |
| `python3` / `python` | **Opt-in via `BashPython`**: embedded CPython runtime (`python3 [OPTIONS] [-c CODE | -m MODULE | FILE] [ARGS...]`); supports `-c`, `-m`, `-V/--version`, stdin execution, and script/module execution against strict shell-filesystem shims (process/FFI escape APIs blocked) |
| `secrets` / `secret` | **Opt-in via `BashSecrets`**: `put`, `ref`, `get`, `delete`, `run`; Keychain generic-password backend with reference-first flows (`secretref:v1:...`) and explicit `get --reveal` for plaintext output |
| `jq` | `-r`, `-c`, `-e`, `-s`, `-n`, `-j`, `-S`; query + optional files. Query subset supports paths, `|`, `select(...)`, comparisons, `and`/`or`/`not`, `//` |
| `yq` | `-r`, `-c`, `-e`, `-s`, `-n`, `-j`, `-S`; query + optional files (YAML + JSON input), same query subset as `jq` |
| `xan` | subcommands: `count`, `headers`, `select`, `filter` |

### Compression & Archives

| Command | Supported Options |
| --- | --- |
| `gzip` | `-d`, `--decompress`, `-c`, `-k`, `-f` |
| `gunzip` | `-c`, `-k`, `-f` |
| `zcat` | positional files (or stdin) |
| `zip` | `-r`, `-0`, `--store`; `zip <archive.zip> <paths...>` |
| `unzip` | `-l`, `-p`, `-o`, `-d <dir>` |
| `tar` | `-c`, `-x`, `-t`, `-z`, `-f <archive>`, `-C <dir>` |

### Navigation & Environment

| Command | Supported Options |
| --- | --- |
| `basename` | positional names; `-a`, `-s <suffix>` |
| `cd` | optional positional path |
| `dirname` | positional paths |
| `du` | `-s` |
| `echo` | `-n` |
| `env` | none |
| `export` | positional `KEY=VALUE` assignments |
| `find` | paths + expression subset: `-name/-iname`, `-path/-ipath`, `-regex/-iregex`, `-type`, `-mtime`, `-size`, `-perm`, `-maxdepth/-mindepth`, `-a/-o/!` with grouping `(...)`, `-prune`, `-print/-print0/-printf`, `-delete`, `-exec ... \\;` / `-exec ... +` |
| `hostname` | none |
| `printenv` | optional positional keys (non-zero if any key is missing) |
| `pwd` | none |
| `tee` | `-a` |

### Shell Utilities

| Command | Supported Options |
| --- | --- |
| `clear` | none |
| `date` | `-u` |
| `false` | none |
| `fg` | optional job spec (`fg`, `fg %1`) |
| `help` | optional command name (`help <command>`) |
| `history` | `-n`, `--n` |
| `jobs` | none |
| `kill` | `kill [-s SIGNAL | -SIGNAL] <pid|%job>...`, `kill -l` |
| `ps` | `ps`, `ps -p <pid[,pid...]>`, compatibility flags `-e`, `-f`, `-a`, `-x`, `aux` |
| `seq` | `-s <separator>`, `-w`, positional numeric args |
| `sleep` | positional durations (`NUMBER[SUFFIX]`, suffix: `s`, `m`, `h`, `d`) |
| `time` | `time <command...>` |
| `timeout` | `timeout <seconds> <command...>`; uses effective elapsed time and excludes host permission callback waits |
| `true` | none |
| `wait` | optional job specs (`wait`, `wait %1`) |
| `whoami` | none |
| `which` | `-a`, `-s`, positional command names |

### Network Commands

| Command | Supported Options |
| --- | --- |
| `curl` | URL argument; `-s`, `-S`, `-i`, `-I`, `-f`, `-L`, `-v`, `-X <method>`, `-H <header>...`, `-A <ua>`, `-e <referer>`, `-u <user:pass>`, `-b <cookie|@file|file>`, `-c <cookie-jar-file>`, `-d/--data <value>...`, `--data-raw <value>...`, `--data-binary <value>...`, `--data-urlencode <value>...`, `-T <file>`, `-F <name=value|name=@file>`, `-o <file>`, `-O`, `-w <format>`, `-m <seconds>`, `--connect-timeout <seconds>`, `--max-redirs <count>`; supports `data:`, `file:`, and HTTP(S) URLs (`file:` is scoped to the shell filesystem root) |
| `wget` | URL argument; `--version`, `-q/--quiet`, `-O/--output-document <file>`, `--user-agent <ua>` |
| `html-to-markdown` | `-b/--bullet <marker>`, `-c/--code <fence>`, `-r/--hr <rule>`, `--heading-style <atx|setext>`; input from file or stdin; strips `script/style/footer` blocks; supports nested lists and Markdown table rendering |

When `SessionOptions.secretPolicy` is `.resolveAndRedact` or `.strict`, `curl` resolves `secretref:v1:...` tokens in headers/body arguments and output redaction replaces resolved values with their reference tokens.
When `SessionOptions.networkPolicy` is set, `curl`/`wget`, `git clone` remotes, and `BashPython` socket connections enforce the same built-in default-off HTTP(S), allowlist, and private-range rules.
When `SessionOptions.permissionHandler` is set, shell filesystem operations and redirections ask it before reading or mutating files, `curl` and `wget` ask it before outbound HTTP(S) requests, `git clone` asks it before remote clones, and `BashPython` asks it before socket connections. Permission callback wait time is excluded from both `timeout` and run-level wall-clock budgets. `data:` and jailed `file:` URLs do not trigger network checks.

## Command Behaviors and Notes

- Unknown commands return exit code `127` and write `command not found` to `stderr`.
- Non-zero command exits are returned in `CommandResult.exitCode` (not thrown).
- `BashSession.init` can throw; `run` always returns `CommandResult` (including parser/runtime failures with exit code `2`).
- Pipelines are currently sequential and buffered (`stdout` from one command becomes `stdin` for the next command).

## Eval Runner and Profiles

`BashEvalRunner` executes NL shell tasks from YAML task banks and validates results with deterministic shell checks.
Use it to compare Bash.swift against system bash and track parser/command parity over time.

Primary eval docs live in `docs/evals/README.md`.

Profiles:
- `docs/evals/general/profile.yaml`: broad command and workflow cross-section with `core` and `gap-probe` tiers.
- `docs/evals/language-deep/profile.yaml`: shell-language stress profile for command substitution, `for` loops, functions, redirection edges, and control-flow probes.

Build runner:

```bash
swift build --target BashEvalRunner
```

Run `general` with static command plans:

```bash
swift run BashEvalRunner \
  --profile docs/evals/general/profile.yaml \
  --engine bashswift \
  --commands-file docs/evals/examples/commands.json \
  --report /tmp/bash-eval-report.json
```

Run `language-deep` with static command plans:

```bash
swift run BashEvalRunner \
  --profile docs/evals/language-deep/profile.yaml \
  --engine bashswift \
  --commands-file docs/evals/language-deep/commands.json \
  --report /tmp/bash-language-deep-report.json
```

Run with an external planner command:

```bash
swift run BashEvalRunner \
  --profile docs/evals/general/profile.yaml \
  --engine bashswift \
  --agent-command './scripts/plan_commands.sh' \
  --report /tmp/bash-eval-report.json
```

## Testing

```bash
swift test
```

The project currently includes parser, filesystem, integration, and command coverage tests.

## Roadmap

### Priority (next)
1. `curl` advanced parity: cookie-jar/edge parsing, multipart/upload depth, verbose/error-code alignment
2. `xargs` advanced GNU parity: size limits, prompt mode, delimiter/empty-input edge semantics
3. `html-to-markdown` robustness: malformed HTML recovery and richer table semantics (`colspan`/`rowspan`/alignment)
4. `sqlite3` advanced parity: `-box`, `-html`, `-quote`, `-tabs`, dot-commands, and shell-level compatibility polish

### Deferred for later milestones
- `git` parity expansion
- query engine parity expansion for `jq` / `yq` (functions, assignments, richer streaming behavior)
- command edge-case parity for file utilities (`cp`, `mv`, `ln`, `readlink`, `touch`)
- `python3` advanced parity (broader CLI flags, richer stdlib/package parity, hardening and execution controls)
