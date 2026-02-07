# Command Parity Gap Tracker

This document tracks command-level parity gaps ("delinquencies") between `BashSwift` and `just-bash`, plus a recommended closure path that prefers internal implementations over new third-party dependencies.

Reference baseline:
- `just-bash-main/src/commands/**`

Dependency policy for gap closure:
- Prefer `Foundation`, Swift stdlib, and existing `BashSwift` utilities.
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

Source references: `grep`, `rg`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`, `awk`, `sed`, `printf`, `base64`, `md5sum`, `sha1sum`, `sha256sum`.

- `grep` (`P0`)  
  Gap: currently substring match only; lacks real regex and major flags (`-E/-F/-c/-l/-L/-o/-w/-x/-r`, context flags).  
  Plan: move to a shared match engine using Swift Regex / `NSRegularExpression` plus fixed-string and recursive modes.

- `rg` (`P0`)  
  Gap: broad feature gap vs ripgrep-like behavior (pattern files, type filters, no-ignore modes, max-count, output modes, stats, JSON/vimgrep).  
  Plan: keep current core; add high-value subset for LLM workflows: `-e/-f/-m/-w/-x/--no-ignore/-t/-T` and better file filtering first.

- `head` (`P1`)  
  Gap: missing `-q/-v` header behavior parity for multi-file use.  
  Plan: add quiet/verbose switches and align headers.

- `tail` (`P1`)  
  Gap: missing `-q/-v` and `-n +N` semantics.  
  Plan: add `from-line` mode (`+N`) and header controls.

- `wc` (`P1`)  
  Gap: missing `-m/--chars` and parity formatting nuances.  
  Plan: add character-count mode (grapheme-aware) and align totals formatting.

- `sort` (`P0`)  
  Gap: missing many common flags (`-b/-d/-f/-h/-M/-V/-c/-o/-s/-t`) and robust key-spec parser.  
  Plan: expand comparator pipeline incrementally; add check-only and output-file early.

- `uniq` (`P1`)  
  Gap: missing `-i` ignore-case and input/output file modes.  
  Plan: add case-fold compare and optional output-file operand support.

- `cut` (`P1`)  
  Gap: missing `-c` character mode and `-s` behavior parity.  
  Plan: add range parser supporting `N`, `N-M`, `-M`, `N-` for both fields/chars.

- `tr` (`P0`)  
  Gap: missing core options `-d/-s/-c`, range/class expansion, escape handling parity.  
  Plan: build an internal character-set expander (`a-z`, POSIX classes, escapes) and process modes in order (`delete`, `translate`, `squeeze`).

- `awk` (`P0`)  
  Gap: current implementation is intentionally tiny compared with AST-based `just-bash` awk.  
  Plan: grow toward an internal lexer/parser/interpreter architecture; phase 1 adds `-v`, assignments, control flow, arithmetic, associative arrays, built-ins used by common scripts.

- `sed` (`P0`)  
  Gap: current command subset is limited (`s`/`p`) with partial addressing; `-E` currently parsed but not meaningfully applied.  
  Plan: implement command AST + executor phases: (`d`,`a`,`i`,`c`,`g/G`,`h/H`,`x`,`n/N`,`y`,`q`,`b/t/:`) plus `-f`; keep engine internal.

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

Source references: `jq`, `yq`, `xan`, plus `just-bash-main/src/commands/query-engine/**`.

- `jq` (`P0`)  
  Gap: current query parser only supports dot/bracket traversal and iteration; no operators/functions/pipelines/filters/assignments; missing `-e/-s/-n/-j/-S/--tab`.  
  Plan: replace `StructuredDataQuery` with a real expression parser (Pratt parser) + evaluator over JSON values; implement option flags in phases.

- `yq` (`P0`)  
  Gap: currently YAML+JSON only and shares limited jq subset; missing format matrix (XML/INI/CSV/TOML), conversion flags, slurp/null-input/in-place/front-matter.  
  Plan: keep jq parser shared, then add format adapters one-by-one with internal parsers/writers (start JSON+YAML hardening, then TOML/INI, then XML/CSV).

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

- `basename` (`P1`)  
  Gap: missing suffix stripping (`-s`) parity.  
  Plan: add optional suffix argument + `-a` semantics.

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

- `find` (`P0`)  
  Gap: very small subset vs expression engine in `just-bash`; missing many predicates/actions (`-iname`, regex, size/perm/time, `-exec`, `-print0`, `-printf`, `-delete`, `-prune`, boolean operators).  
  Plan: build a small expression parser + evaluator incrementally; add `-exec` and `-print0` early for LLM scripts.

- `printenv` (`P1`)  
  Gap: missing non-zero exit for unknown variables.  
  Plan: return `1` when any requested key is absent.

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

- `help` (`P1`)  
  Gap: currently lists commands only; missing `help <command>` forwarding and category formatting.  
  Plan: support optional command argument and delegate to `<cmd> --help`.

- `history` (`P1`)  
  Gap: missing clear mode (`-c`) and numeric argument parity.  
  Plan: add clear/reset and ensure line numbering/padding compatibility.

- `seq` (`P1`)  
  Gap: missing `-s` separator and `-w` zero-padding.  
  Plan: add separator/padding while retaining numeric parsing.

- `sleep` (`P1`)  
  Gap: only raw seconds accepted; missing duration suffixes (`s/m/h/d`) and multiple operands sum behavior.  
  Plan: parse duration tokens and sum.

- `time` (`P1`)  
  Gap: missing formatting/output options (`-p`, `-f`, `-o`, `-a`, `-v`).  
  Plan: add simple formatter and optional file output; keep CPU/memory fields best-effort.

- `timeout` (`P1`)  
  Gap: duration parser is seconds-only, missing suffix support and option handling (`-k`, `-s`, `--preserve-status`, `--foreground`).  
  Plan: add duration parser + option parsing; keep signal model virtual.

- `which` (`P1`)  
  Gap: missing `-a` and `-s`.  
  Plan: add all-match and silent modes.

## Closure Roadmap (Dependency-Light)

1. `P0` engine gaps: `jq`, `yq`, `xan`, `grep`, `rg`, `awk`, `sed`, `find`, `cp/mv` multi-source, `file`.
2. `P1` high-utility flags: `sort`, `tr`, `touch`, `tar`, `env`, `date`, `timeout`, `time`, `which`, `seq`, `sleep`.
3. `P2` polish/output parity: formatting consistency, extra flags, minor exit-code edge behavior.

## Test Expectations Per Gap

For each command as gaps close:
- Add one success case and one failure case in `Tests/BashSwiftTests/SessionIntegrationTests.swift`.
- Add `--help` assertion in `Tests/BashSwiftTests/CommandCoverageTests.swift` when new options are added.
- Add parser-specific unit tests where command option parsing gets complex (`rg`, `sed`, `awk`, `find`, `tar`, `jq`, `yq`).
