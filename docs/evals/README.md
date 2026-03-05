# Eval Setup

This directory defines practical eval profiles for Bash.swift.

The intent is to answer two questions:
1. How often does Bash.swift complete realistic NL shell tasks end-to-end?
2. What gaps appear in the commands and shell language patterns that modern LLMs naturally use?

## Profiles

### `general`

- Environment: Debian GNU userland (containerized)
- Task bank: deterministic file-system-centric tasks with shell validators
- Tiers:
  - `core`: should become Bash.swift parity targets
  - `gap-probe`: informational tasks for discovering missing commands/language support

### `language-deep`

- Focused shell-language stress profile (command substitution, `for`, functions, redirection edges, and control-flow probes)
- Task bank and matching command plans are checked in for direct regression runs
- Best used as a fix-it queue while expanding parser/runtime behavior

## Why This Shape

- Uses a broad but stable GNU command set that maps well to agent behavior.
- Separates "shipping parity" (`core`) from "future surface discovery" (`gap-probe`).
- Uses deterministic validators so failures can be triaged automatically.

## Suggested Run Matrix

Run each task against both environments with the same model + prompting:

1. Baseline: real `/bin/bash` in `general` container.
2. Candidate: Bash.swift-backed shell tool in same workspace fixture.

Compare pass/fail and trace deltas.

## Recommended Metrics

- `core_pass_rate`: primary quality metric.
- `gap_probe_pass_rate`: informational only.
- `unsupported_command_rate`: fraction of failing tasks whose first failure is `command not found`.
- `parser_or_language_gap_rate`: fraction of failing tasks due to syntax features not implemented.
- `semantic_mismatch_rate`: command exists but behavior/output/exit code differs.
- `median_steps_to_pass`: efficiency measure on passing tasks.

## Failure Taxonomy

Classify first failure into one bucket:

- `missing-command`
- `unsupported-flag`
- `parser-language-gap`
- `pipeline-redirection-mismatch`
- `filesystem-state-mismatch`
- `stdout-stderr-mismatch`
- `exit-code-mismatch`
- `agent-error` (model logic error unrelated to shell capabilities)

## Run Contract (Runner-Agnostic)

For each task:

1. Reset workspace to clean temp dir.
2. Execute `setup` commands in baseline bash.
3. Provide `prompt` to the agent.
4. Let the agent issue shell commands until stop condition (`max_steps`, success signal, or timeout).
5. Execute each `validate` command in baseline bash; task passes only if all return `0`.
6. Persist artifacts:
   - full command trace
   - tool outputs and exit codes
   - validator results
   - bucketed failure reason

## Files

- `docs/evals/general/profile.yaml`
- `docs/evals/general/tasks.yaml`
- `docs/evals/general/Dockerfile`
- `docs/evals/language-deep/profile.yaml`
- `docs/evals/language-deep/tasks.yaml`
- `docs/evals/language-deep/commands.json`
- `docs/evals/language-deep/README.md`

## BashEvalRunner CLI

`BashEvalRunner` is a lightweight local runner that reads the profile/task YAML,
executes task setup + candidate commands + validators, and emits a JSON report.

### Build

```bash
swift build --target BashEvalRunner
```

### Run with static command plans

```bash
swift run BashEvalRunner \
  --profile docs/evals/general/profile.yaml \
  --engine bashswift \
  --commands-file docs/evals/examples/commands.json \
  --report /tmp/bash-eval-report.json
```

The checked-in `docs/evals/examples/commands.json` now includes plans for all
tasks in `docs/evals/general/tasks.yaml` (no expected skips from missing plans).

Run `language-deep` with static plans:

```bash
swift run BashEvalRunner \
  --profile docs/evals/language-deep/profile.yaml \
  --engine bashswift \
  --commands-file docs/evals/language-deep/commands.json \
  --report /tmp/bash-language-deep-report.json
```

`commands.json` can be either:

```json
{
  "core.file.create_exact_file": ["echo pass > myfile.txt"],
  "core.shell.chain_and_or": ["false && echo nope > result.txt || echo fallback > result.txt"]
}
```

or:

```json
{
  "tasks": {
    "core.file.create_exact_file": ["echo pass > myfile.txt"]
  },
  "default": ["echo not-implemented"]
}
```

### Run with an external planner command

```bash
swift run BashEvalRunner \
  --profile docs/evals/general/profile.yaml \
  --engine bashswift \
  --agent-command './scripts/plan_commands.sh' \
  --report /tmp/bash-eval-report.json
```

The planner command receives:
- `EVAL_TASK_ID`
- `EVAL_TASK_TIER`
- `EVAL_TASK_PROMPT`
- `EVAL_MAX_STEPS`
- `EVAL_WORKSPACE`

and should print one shell command per line to stdout.

### Notes

- `setup` and `validate` commands run in system `/bin/bash` for deterministic fixtures and checks.
- Candidate commands run in `--engine` (`bashswift` or `system-bash`).
- If no commands are produced for a task, that task is marked `skipped`.
