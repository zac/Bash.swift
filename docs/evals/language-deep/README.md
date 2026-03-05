# language-deep

`language-deep` is a fix-it profile that intentionally stresses shell-language
semantics beyond basic command parity.

## Focus Areas

- Command substitution (`$(...)`), including nesting and quoting
- `for` loops, including newline form, empty lists, and substitution inputs
- Function behavior (definition, persistence, composition, pipelines)
- Function forms and scoping (`function name {}`, `local` shadow/restore)
- Positional-parameter fidelity inside functions (`$1`, `$@`, `$#`)
- Redirection and pipeline edge behavior
- Job control composition with `&` and `wait`
- Control-flow breadth (`if`/`elif`, `while`, `until`, `case`, C-style `for`)
- Arithmetic semantics (`$((...))` comparison/logical/bitwise/power operators)
- Link semantics parity (`ln` hard-link behavior vs copy fallback)

## Expected Use

Run this profile continuously while implementing shell-language support, and
promote stable tasks into your general regression profile once behavior is
reliable.
