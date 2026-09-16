---
name: usage-report
description: Turn on the plugin's debug usage log (SHUNT_DEBUG_LOG) so every real scripts/bulk-read delegation is recorded, and summarize it with scripts/usage-report - delegate tokens/cost actually spent, and a chars/4 estimate of Claude-context tokens avoided by delegating instead of reading the file directly. Use when the user asks how much shunt is saving, wants to track delegate spend over a work session, or wants to turn this tracking on/off.
---

# Usage Report

Tracks the delegate side of every real `scripts/bulk-read` call made during
normal work (not `evals/*` benchmark runs, which measure this separately and
don't need the toggle below): what the delegate model actually cost
(`delegate_input_tokens`/`delegate_output_tokens`/`delegate_cost_usd`, from
OpenCode's own usage report), and a chars/4 estimate of the tokens Claude's
own context avoided by not reading the delegated file(s) directly
(`avoided_tokens_estimate` - the same heuristic `evals/benchmark.sh`
documents and uses).

## What this does NOT measure

This plugin's hooks only ever see `tool_input`/file content - they have no
access to Claude Code's own token accounting or billing. So this log can
tell you what the delegate model cost and roughly how much context
delegation kept out of Claude's hands, but **not** what Claude itself
actually spent for the session. For that, use Claude Code's own `/cost`
command (or the `ecc:cost-report` skill, if installed) - read the two
side by side rather than expecting this log to include Claude's spend.

## Turning logging on

Off by default (`SHUNT_DEBUG_LOG` unset). To enable for the current project:

- Read `.claude/settings.local.json` in the project root if it exists
  (create it with `{}` if not - this file is per-user and gitignored, never
  `.claude/settings.json`, which is shared).
- Merge in `{"env": {"SHUNT_DEBUG_LOG": "1"}}`, preserving any other keys
  already in the file (same mechanism the `/toggle-hooks` skill uses for
  `SHUNT_HOOKS_DISABLED`).
- Tell the user: this file is read by Claude Code at session start, so if
  logging doesn't start on the very next delegated `bulk-read` call, restart
  the session.
- To disable again, remove the `SHUNT_DEBUG_LOG` key from `env` (delete the
  `env` object too if it becomes empty), preserving everything else.

Alternatively, for a one-off session: `SHUNT_DEBUG_LOG=1 claude`.

Each enabled call appends one line to `SHUNT_DEBUG_LOG_PATH` (default
`~/.cache/cc-model-shunt/usage.jsonl`): `timestamp`, `agent`, `files`
(`path`/`lines`/`bytes` per delegated file), `question_chars`,
`delegate_input_tokens`, `delegate_output_tokens`, `delegate_cost_usd`,
`avoided_tokens_estimate`.

## Reading the report

```bash
scripts/usage-report
```

Prints total calls, summed delegate tokens/cost, summed
`avoided_tokens_estimate`, and the same broken down per agent (useful once
more than one delegate model/agent is configured). Pass a path to summarize
a different log file: `scripts/usage-report /path/to/usage.jsonl`.

## When to use this skill

- The user asks how much delegating to shunt has saved, or wants to see
  real (not benchmark) usage numbers for the delegate model over a session.
- The user wants to turn usage tracking on or off.

## When NOT to use this skill

- For a controlled, repeatable token/cost/latency comparison instead of live
  session tracking, use `evals/benchmark.sh` and
  `evals/baseline-benchmark.sh` instead - they measure both sides
  (direct-read vs delegated) deliberately, rather than opportunistically
  logging whatever real calls happen to occur.
