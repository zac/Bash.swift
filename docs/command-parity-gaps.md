# Command Parity Gap Tracker

This document tracks command-level parity gaps ("delinquencies") between `Bash` and `just-bash`, plus a recommended closure path that prefers internal implementations over new third-party dependencies.

Reference baseline:
- `just-bash-main/src/commands/**`

Dependency policy for gap closure:
- Prefer `Foundation`, Swift stdlib, and existing `Bash` utilities.
- Avoid new external libraries unless the command is effectively infeasible without one.
- If full parity is large, ship in phases: common LLM paths first, edge semantics second.

Priority legend:
- `P0`: High-impact correctness or major feature gap for common usage.
- `P1`: Important options/behavior used frequently in scripts.
- `P2`: Nice-to-have parity and edge compatibility.

## File Operations

Source references: `cat`, `cp`, `ln`, `ls`, `mkdir`, `mv`, `readlink`, `rm`, `rmdir`, `stat`, `touch`, `chmod`, `file`, `tree`, `diff`.

- `cat` (`P1`)  
  Gap: missing `-n/--number` line numbering and stdin marker handling parity (`-`).  
  Plan: add streaming line counter and explicit `-` operand support; keep current byte-pass-through behavior.

- `cp` (`P0`)  
  Gap: currently enforces exactly one source + one destination; missing multi-source copy and `-n/-p/-v`.  
  Plan: support `SOURCE... DEST` semantics first, then `-n` no-clobber and `-v`; accept `-p` as best-effort metadata preservation (mode/mtime where available).

- `ln` (`P0`)  
  Gap: non-`-s` mode currently behaves like copy, not hard link semantics; missing `-f/-v/-n`.  
  Plan: add `filesystem.createHardLink` capability (or explicit unsupported), implement proper target/link behavior and force overwrite.

- `ls` (`P1`)  
  Gap: missing `-A/-d/-h/-r/-R/-S/-t/-1`; long output format is minimal.  
  Plan: implement sort modes and recursive traversal first, then display flags (`-A/-d/-1`) and human-readable sizes.

- `mkdir` (`P2`)  
  Gap: missing `-v`.  
  Plan: add optional verbose output only; keep current behavior.

- `mv` (`P0`)  
  Gap: currently enforces exactly one source + one destination; missing multi-source mode and `-f/-n/-v`.  
  Plan: implement `SOURCE... DEST` with directory target handling; add no-clobber/verbose.

- `readlink` (`P1`)  
  Gap: missing `-f` canonicalization and multi-operand support.  
  Plan: add iterative symlink resolution with cycle guard and path normalization.

- `rm` (`P2`)  
  Gap: missing `-v` and nuanced `-f`/no-operand behavior.  
  Plan: add verbose output and align exit behavior for `rm -f` edge cases.

- `rmdir` (`P1`)  
  Gap: missing `-p/--parents` and `-v`.  
  Plan: implement parent-chain removal with stop-on-first-nonempty semantics.

- `stat` (`P1`)  
  Gap: missing `-c FORMAT` tokens.  
  Plan: add a small format-token engine (`%n`, `%s`, `%F`, `%a`, `%A`, `%m` baseline).

- `touch` (`P1`)  
  Gap: missing `-d`, `-c`, `-a`, `-m`, `-r`, `-t`.  
  Plan: add timestamp parser + mode flags incrementally (`-d/-c` first, then `-a/-m/-r/-t`).

- `chmod` (`P2`)  
  Gap: missing `-v`; symbolic mode coverage is narrower than GNU edge cases.  
  Plan: add `-v`; keep symbolic parser strict and extend only where script demand appears.

- `file` (`P0`)  
  Gap: very shallow type detection vs `just-bash` (`-b/-i/-L`, magic-byte detection).  
  Plan: implement an internal magic-byte table for common formats (image/archive/audio/video/executable) + MIME mode; no dependency required.

- `tree` (`P1`)  
  Gap: missing `-d` (dirs only), `-f` (full path), and summary counts.  
  Plan: add output mode flags + final counts in the renderer.

- `diff` (`P1`)  
  Gap: missing `-q/-s/-i`; current unified output is simplistic.  
  Plan: add quick/identical/ignore-case modes first; refine hunk generation with an internal LCS-based differ (no `diff` package).

## Text Processing

Source references: `grep`, `rg`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`, `awk`, `sed`, `xargs`, `printf`, `base64`, `md5sum`, `sha1sum`, `sha256sum`.

- `grep` (`P1`)  
  Gap: now supports regex/fixed modes and major flags (`-E/-F/-c/-l/-L/-o/-w/-x/-r`, `-e/-f`, aliases). Remaining gaps are mainly context-grouping/output polish and deeper GNU compatibility edges.
  Plan: add context flags (`-A/-B/-C`) and align output separators/exit nuances for edge cases.

- `rg` (`P1`)  
  Gap: high-value subset now implemented (`-e/-f/-m/-w/-x/--no-ignore/-t/-T` plus existing context/glob/file listing flags). Remaining gaps are advanced output modes/stats/config parity (`--json`, vimgrep, stats, richer ignore/type ecosystems).
  Plan: add structured output modes (`--json`, `--vimgrep`) and richer ignore/type metadata incrementally.

- `head` (`Done: 2026-02-07`)  
  Gap closed for v1 target: supports `-q/-v` header behavior and byte/line modes.

- `tail` (`Done: 2026-02-07`)  
  Gap closed for v1 target: supports `-q/-v` and `-n +N` (from-line) semantics.

- `wc` (`P2`)  
  Gap: now supports `-m/--chars`; remaining delinquencies are mostly output-format parity nuances.
  Plan: align column formatting/spacing to common wc output conventions.

- `sort` (`P0`)  
  Gap: now supports `-f`, `-c`, and `-o`; still missing many common flags (`-b/-d/-h/-M/-V/-s/-t`) and robust key-spec parser.  
  Plan: expand comparator pipeline incrementally; keep key-spec parser and advanced comparators as next slice.

- `uniq` (`P2`)  
  Gap: `-i` and input/output operand support are implemented; remaining gaps are mostly formatting polish.
  Plan: align count-field formatting and edge-case messaging.

- `cut` (`P2`)  
  Gap: `-c`, `-s`, and range syntax (`N`, `N-M`, `-M`, `N-`) are implemented; remaining gaps are secondary modes.
  Plan: add byte-list mode (`-b`) and delimiter/output parity refinements.

- `tr` (`P1`)  
  Gap: core options `-d/-s/-c`, range expansion, and escape handling are implemented; missing POSIX classes and full complement parity across full Unicode domains.
  Plan: extend character-set parser for POSIX classes (`[:digit:]`, etc.) and tighten GNU behavior compatibility.

- `awk` (`P0`)  
  Gap: current implementation is intentionally tiny compared with AST-based `just-bash` awk.  
  Plan: grow toward an internal lexer/parser/interpreter architecture; phase 1 adds `-v`, assignments, control flow, arithmetic, associative arrays, built-ins used by common scripts.

- `sed` (`P0`)  
  Gap: current command subset is limited (`s`/`p`) with partial addressing; `-E` currently parsed but not meaningfully applied.  
  Plan: implement command AST + executor phases: (`d`,`a`,`i`,`c`,`g/G`,`h/H`,`x`,`n/N`,`y`,`q`,`b/t/:`) plus `-f`; keep engine internal.

- `xargs` (`P1`)  
  Gap: practical subset now includes `-I`, `-d`, `-n`, `-L/--max-lines`, `-E/--eof`, `-P`, `-0/--null`, `-t/--verbose`, and `-r/--no-run-if-empty`, with command execution via shell subcommands and cwd propagation. Remaining gaps are deeper GNU compatibility (size limits, prompt mode, and exact delimiter/empty-input edge semantics).
  Plan: keep the current execution engine and add option-surface/edge-semantics parity incrementally, starting with size-limit and prompt-mode behavior.

- `printf` (`P1`)  
  Gap: missing width/precision/flag formatting, `%x/%o`, `-v` assignment.  
  Plan: implement a constrained internal formatter for common specifiers and width/precision; avoid external formatting libs.

- `base64` (`P1`)  
  Gap: missing wrap control (`-w`) and stronger binary-mode semantics.  
  Plan: add wrapping and binary-safe decode/encode paths for file/stdin with minimal copying.

- `md5sum`, `sha1sum`, `sha256sum` (`P1`)  
  Gap: missing `--check` verification mode.  
  Plan: parse checksum manifests (`HASH  file`) and emit `OK/FAILED` output + aggregate exit codes.

## Data Processing

Source references: `jq`, `yq`, `xan`, `sqlite3`, `python3/python`, plus `just-bash-main/src/commands/query-engine/**`.

- `python3` / `python` (`P1`)  
  Status: v1 optional module shipped in `BashPython`, with `python3`/`python` command registration, argument surface (`-c`, `-m`, script file, stdin, `-V/--version`), and runtime request mapping that carries env/cwd/argv/stdin through to a Pyodide-backed runtime. Filesystem access is bridged to `ShellFilesystem` so Python file operations stay inside the shell filesystem model.
  Gap: broad parity gaps remain vs just-bash Python surface (security hardening depth, timeout/signal controls, richer stdlib/import/network behavior, and edge-flag compatibility).
  Plan: close in slices: (1) runtime hardening and deterministic timeout controls, (2) option-surface and error-message parity, (3) stdlib/import compatibility and test parity expansion.

- `sqlite3` (`P1`)  
  Status: v1 optional module shipped in `BashSQLite` with `sqlite3 [options] [database] [sql]`, modes (`-list/-csv/-json/-line/-column/-table/-markdown`), control flags (`-header/-noheader/-separator/-newline/-nullvalue/-readonly/-bail/-cmd/-version/--`), `:memory:` support, stdin SQL support, and persistence through `ShellFilesystem` for both `ReadWriteFilesystem` and `InMemoryFilesystem`.
  Gap: no dot-commands (`.schema`, `.read`, `.mode`), no advanced output modes (`-box`, `-html`, `-quote`, `-ascii`, `-tabs`), and no shell-level sqlite meta-command parity.
  Plan: add advanced output modes first, then safe subset of dot-commands, then deeper sqlite-shell UX parity.

- `jq` (`P1`)  
  Gap: phase-1 parser/evaluator landed with paths, pipes, `select(...)`, comparisons, boolean operators, and `//`, plus flags `-e/-s/-n/-j/-S`. Remaining gaps are advanced jq semantics (functions/assignments/reduce, richer operators, stream semantics, `--tab` formatting parity).  
  Plan: add function/value pipeline primitives (`map`, `length`, `keys`, `add`) and tighten stream semantics incrementally.

- `yq` (`P1`)  
  Gap: now shares the same phase-1 jq subset and flags (`-e/-s/-n/-j/-S`) for YAML+JSON. Remaining gaps are format matrix expansion (XML/INI/CSV/TOML) and yq-specific conversion/editing features (in-place/front-matter/input-output format controls).  
  Plan: keep shared query engine and add format adapters one-by-one with internal parsers/writers.

- `xan` (`P0`)  
  Gap: only `count/headers/select/filter` with simple selection; missing broad subcommand surface and expression language.  
  Plan: expand around high-value ops first (`search`, `sort`, `head`, `tail`, `map`, `groupby`, `frequency`) using a shared column-selector + expression evaluator.

## Compression & Archives

Source references: `gzip`, `tar`.  
Note: `just-bash` does not currently provide `zip`/`unzip` command implementations to parity-check against.

- `gzip` / `gunzip` / `zcat` (`P1`)  
  Gap: missing `-l/-t/-q/-r/-S/-n/-N` and compression-level flags (`-1..-9`).  
  Plan: add integrity test/list first, then suffix/recursive and compression-level control.

- `tar` (`P0`)  
  Gap: missing many operational flags (`-r/-u/-v/-O/-k/-m/--strip-components/--exclude/-T/-X/--wildcards`).  
  Plan: extend option parser and archive walker in phases; prioritize `-v`, exclude patterns, and strip-components for extraction.

- `zip` (`P1`)  
  Gap (vs common CLI behavior): no exclusion globs, no update/freshen, no comment/password/list-test modes.  
  Plan: keep scope narrow; add `-q` quiet, exclusion globs, and update mode before advanced features.

- `unzip` (`P1`)  
  Gap: no wildcard pattern selection semantics, no test mode, limited listing metadata.  
  Plan: add glob-based include/exclude and `-t` archive test; keep extraction behavior deterministic.

## Navigation & Environment

Source references: `basename`, `dirname`, `du`, `echo`, `env`, `printenv`, `find`, `tee`.
Shell builtins in `just-bash` handle `cd`, `export`, `pwd`.

- `basename` (`Done: 2026-02-07`)  
  Gap closed for v1 target: supports `-a` and `-s <suffix>`.

- `cd` (`P1`)  
  Gap: missing shell parity (`cd -`, `OLDPWD`, logical/physical modes).  
  Plan: add `OLDPWD` tracking and `cd -` first; keep symlink mode flags as phase 2.

- `dirname` (`P2`)  
  Gap: minimal; mostly aligned for common usage.  
  Plan: no immediate change.

- `du` (`P1`)  
  Gap: only `-s` today; missing `-a/-h/-c/--max-depth`.  
  Plan: add human-readable and max-depth, then file-inclusive and grand total.

- `echo` (`P1`)  
  Gap: missing `-e/-E` escape behavior and `\c` stop semantics.  
  Plan: add opt-in escape parser + strict flag compatibility.

- `env` (`P0`)  
  Gap: print-only today; missing command-exec mode and env mutation flags (`-i/-u`, assignments before command).  
  Plan: implement command invocation through existing `runSubcommand` path with temporary environment.

- `export` (`P1`)  
  Gap: missing common forms (`-p` style output parity, stricter identifier validation).  
  Plan: validate identifiers and align printed format.

- `find` (`P1`)  
  Gap narrowed further: now supports boolean expression parsing (`-a/-o/!` + parentheses), `-prune`, `-print0`, `-printf`, `-delete`, metadata predicates (`-regex/-iregex`, `-size`, `-mtime`, `-perm`), and `-exec ... \;` / `-exec ... +` with short-circuit evaluation. Remaining gaps are advanced predicates/actions (`-newer`, `-empty`, `-depth`) plus deeper GNU output/error edge parity.  
  Plan: next slice should add `-newer` + `-empty`, then `-depth` traversal semantics and output-format nuances.

- `printenv` (`Done: 2026-02-07`)  
  Gap closed for v1 target: returns non-zero when any requested key is missing.

- `pwd` (`P2`)  
  Gap: no `-L/-P` distinction.  
  Plan: optional later if symlink semantics are expanded.

- `tee` (`P2`)  
  Gap: mostly aligned (`-a` present).  
  Plan: add error message parity only if needed.

- `hostname` (`P2`)  
  Gap: behavior differs by environment (host-derived vs fixed sandbox value).  
  Plan: decide deterministic session-level hostname policy; keep no-flag behavior.

## Shell Utilities

Source references: `clear`, `date`, `history`, `seq`, `sleep`, `time`, `timeout`, `which`, `help`.

- `clear` (`P2`)  
  Gap: none material.  
  Plan: no change.

- `date` (`P1`)  
  Gap: current implementation is minimal (`-u` only) vs common date formatting (`+FORMAT`, `-d`, `-I`, `-R`).  
  Plan: add format token engine and date parsing subset.

- `false` / `true` (`P2`)  
  Gap: none material.

- `whoami` (`P2`)  
  Gap: none material (session-level identity is acceptable).

- `help` (`P2`)  
  Gap reduced: now supports `help <command>` forwarding. Remaining gap is categorized/grouped output formatting.

- `history` (`P1`)  
  Gap: missing clear mode (`-c`) and numeric argument parity.  
  Plan: add clear/reset and ensure line numbering/padding compatibility.

- `seq` (`Done: 2026-02-07`)  
  Gap closed for v1 target: supports `-s` separator and `-w` equal-width zero padding.

- `sleep` (`Done: 2026-02-07`)  
  Gap closed for v1 target: supports `NUMBER[SUFFIX]` (`s/m/h/d`) and sums multiple duration operands.

- `time` (`P1`)  
  Gap: missing formatting/output options (`-p`, `-f`, `-o`, `-a`, `-v`).  
  Plan: add simple formatter and optional file output; keep CPU/memory fields best-effort.

- `timeout` (`P1`)  
  Gap: duration parser is seconds-only, missing suffix support and option handling (`-k`, `-s`, `--preserve-status`, `--foreground`).  
  Plan: add duration parser + option parsing; keep signal model virtual.

- `which` (`Done: 2026-02-07`)  
  Gap closed for v1 target: supports `-a` (all matches) and `-s` (silent status mode).

## Network Commands

Source references: `curl`, `html-to-markdown`.

- `curl` (`P1`)  
  Gap: expanded subset now supports `-s/-S`, `-i`, `-I`, `-f`, `-L`, `-v`, `-X`, `-H`, `-A`, `-e`, `-u`, `-b` (literal, `@file`, and file-path fallback), `-c` cookie-jar output, `-d/--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, `-T`, `-F`, `-o`, `-O`, `-w`, `-m`, `--connect-timeout`, and `--max-redirs`, with URL support for `data:`, `file:`, and HTTP(S). Redirect following now honors `-L`. `file:` remains jailed to the shell filesystem and rejects remote hosts (for example, `file://evil.com/...`).
  Plan: close remaining high-value gaps in slices: richer cookie compatibility (full curl jar semantics and edge parsing), and deeper multipart/upload and verbose/error-code parity. Keep allow-list policy as a separate safety feature.

- `html-to-markdown` (`P1`)  
  Gap: practical conversion now supports stdin/file input, heading/paragraph/link/image/list/blockquote/inline-style conversion, `-b/--bullet`, `-c/--code`, `-r/--hr`, and `--heading-style`, with `script/style/footer` stripping, nested-list indentation, and Markdown table rendering (`table/tr/th/td`). Remaining gap is robustness parity with turndown for malformed/deeply irregular HTML and advanced table semantics (colspan/rowspan/alignment).
  Plan: focus next on malformed-markup recovery and better table semantics without adding external HTML conversion dependencies.

## Optional Modules

- `git` via `BashGit` (`P1`)  
  Status: initial optional module landed with libgit2-backed `git` command surface for `init`, `status` (`--short`), `add` (`-A/--all` + paths), `commit -m`, `log` (`--oneline`, `-n/--max-count`), and `rev-parse --is-inside-work-tree`.
  Gap: broad CLI parity remains (`branch`, `checkout`/`switch`, `restore`, `diff`, `merge`, remotes/fetch/pull/push, config UX, and error-message parity), and current repository projection/sync strategy should later be optimized for large repos.
  Plan: next slices should add `branch` + `checkout -b`, then `diff` + `restore`, then remote plumbing and projection performance improvements.

## Closure Roadmap (Dependency-Light)

1. `P0` engine gaps: `xan`, `awk`, `sed`, `find`, `cp/mv` multi-source, `file`.
2. `P1` high-utility flags: `touch`, `tar`, `env`, `date`, `timeout`, `time`, plus remaining advanced `sort/tr` semantics and `grep/rg` output-mode parity.
3. `P2` polish/output parity: formatting consistency, extra flags, minor exit-code edge behavior.

## Test Expectations Per Gap

For each command as gaps close:
- Add one success case and one failure case in `Tests/BashTests/SessionIntegrationTests.swift`.
- Add `--help` assertion in `Tests/BashTests/CommandCoverageTests.swift` when new options are added.
- Add parser-specific unit tests where command option parsing gets complex (`rg`, `sed`, `awk`, `find`, `tar`, `jq`, `yq`).
