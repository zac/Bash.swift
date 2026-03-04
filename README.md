# Bash.swift

`Bash.swift` provides an in-process, stateful, emulated shell for Swift apps. It's heavily inspired by [just-bash](https://github.com/vercel-labs/just-bash).

You create a `BashSession`, run shell command strings, and get structured `stdout` / `stderr` / `exitCode` results. Commands mutate a real directory on disk through a sandboxed, root-jail filesystem abstraction.

## Development Process

Development of `Bash.swift` was approached very similarly to [just-bash](https://github.com/vercel-labs/just-bash). All output was with GPT-5.3-Codex Extra High thinking, initiated by an interactively built plan, executed by the model after the plan was finalized.

## Contents

- [Why](#why)
- [Installation](#installation)
- [Platform Support](#platform-support)
- [Quick Start](#quick-start)
- [Public API](#public-api)
- [Filesystem Model](#filesystem-model)
- [Implemented Commands](#implemented-commands)
- [Testing](#testing)
- [Roadmap](#roadmap)

## Why

`Bash.swift` is aimed at providing a tool for use in agents. Leveraging the approach that "Bash is all you need". To enable this use-case, it provides:
- Stateful shell session (`cd`, `export`, `history` persist across `run` calls)
- Real filesystem side effects under a controlled root directory
- Built-in fake CLIs implemented in Swift (no subprocess dependency)
- Shell parsing/execution features needed for scripts (`|`, redirection, `&&`, `||`, `;`)

## Installation

### Swift Package Manager (remote package)

```swift
// Package.swift
.dependencies: [
    .package(url: "https://github.com/zac/Bash.swift.git", from: "0.1.0")
],
.targets: [
    .target(
        name: "YourTarget",
        dependencies: ["Bash"]
    )
]
```

`BashSQLite`, `BashPython`, `BashGit`, and `BashSecrets` are optional products. Add them only if needed:

```swift
dependencies: ["Bash", "BashSQLite", "BashPython", "BashGit", "BashSecrets"]
```

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

`BashPython` embeds CPython directly (no JavaScriptCore/Pyodide path). Phase 1 runtime support is macOS + iOS/iPadOS.
On unsupported platforms (`tvOS`, `watchOS`), the module still compiles but runtime execution returns an unavailable error.

Strict filesystem mode is enabled by default. Script-visible file APIs are shimmed through `ShellFilesystem`, so Python file operations share the same jailed root as shell commands.
Blocked escape APIs include `subprocess`, `ctypes`, and process-spawn helpers like `os.system` / `os.popen` / `os.spawn*`.
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
- `secretPolicy`: `.off`
- `secretResolver`: `nil`
- `secretOutputRedactor`: `DefaultSecretOutputRedactor()`

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
1. Command line is lexed and parsed into a shell AST.
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
| `help` | optional command name (`help <command>`) |
| `history` | `-n`, `--n` |
| `seq` | `-s <separator>`, `-w`, positional numeric args |
| `sleep` | positional durations (`NUMBER[SUFFIX]`, suffix: `s`, `m`, `h`, `d`) |
| `time` | `time <command...>` |
| `timeout` | `timeout <seconds> <command...>` |
| `true` | none |
| `whoami` | none |
| `which` | `-a`, `-s`, positional command names |

### Network Commands

| Command | Supported Options |
| --- | --- |
| `curl` | URL argument; `-s`, `-S`, `-i`, `-I`, `-f`, `-L`, `-v`, `-X <method>`, `-H <header>...`, `-A <ua>`, `-e <referer>`, `-u <user:pass>`, `-b <cookie|@file|file>`, `-c <cookie-jar-file>`, `-d/--data <value>...`, `--data-raw <value>...`, `--data-binary <value>...`, `--data-urlencode <value>...`, `-T <file>`, `-F <name=value|name=@file>`, `-o <file>`, `-O`, `-w <format>`, `-m <seconds>`, `--connect-timeout <seconds>`, `--max-redirs <count>`; supports `data:`, `file:`, and HTTP(S) URLs (`file:` is scoped to the shell filesystem root) |
| `html-to-markdown` | `-b/--bullet <marker>`, `-c/--code <fence>`, `-r/--hr <rule>`, `--heading-style <atx|setext>`; input from file or stdin; strips `script/style/footer` blocks; supports nested lists and Markdown table rendering |

When `SessionOptions.secretPolicy` is `.resolveAndRedact` or `.strict`, `curl` resolves `secretref:v1:...` tokens in headers/body arguments and output redaction replaces resolved values with their reference tokens.

## Command Behaviors and Notes

- Unknown commands return exit code `127` and write `command not found` to `stderr`.
- Non-zero command exits are returned in `CommandResult.exitCode` (not thrown).
- `BashSession.init` can throw; `run` always returns `CommandResult` (including parser/runtime failures with exit code `2`).
- Pipelines are currently sequential and buffered (`stdout` from one command becomes `stdin` for the next command).

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
