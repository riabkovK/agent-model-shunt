---
name: usage-report
description: Summarize the plugin's debug usage log (SHUNT_DEBUG_LOG) with scripts/usage-report - delegate tokens/cost actually spent, and a chars/4 estimate of Claude-context tokens avoided by delegating instead of reading the file directly. Use when the user asks how much shunt is saving or wants to track delegate spend over a work session. To turn the underlying logging on or off, use /toggle-debug-log instead.
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

Off by default (`SHUNT_DEBUG_LOG` unset). Use the `/toggle-debug-log` skill
to enable or disable it — it handles editing `.claude/settings.local.json`
and reminds the user to restart the session, since that file is only read
by Claude Code at session start.

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
