---
name: toggle-debug-log
description: Report whether the plugin's SHUNT_DEBUG_LOG usage-tracking env var is currently on or off, then ask the user whether to flip it via .claude/settings.local.json, and tell the user to restart the Claude Code session so the change takes effect. Use when the user wants to start or stop recording delegate usage (tokens/cost) to ~/.cache/cc-model-shunt/usage.jsonl, typically before reading it with /usage-report.
---

# Toggle Debug Log

Turns `scripts/lib/opencode.sh`'s `shunt_log_usage()` recording on or off by
setting `SHUNT_DEBUG_LOG` for the current project. Off by default; when on,
every real `scripts/bulk-read` delegation appends one line to
`SHUNT_DEBUG_LOG_PATH` (default `~/.cache/cc-model-shunt/usage.jsonl`).
`/usage-report` reads that log; this skill only controls whether it's being
written.

## How it works

`shunt_debug_log_enabled()` in `scripts/lib/opencode.sh` checks the
`SHUNT_DEBUG_LOG` environment variable at the time each hook/script runs.
That environment comes from Claude Code, which reads `.claude/settings.local.json`'s
`env` block **at session start** — not on every tool call. So editing the
file mid-session is not guaranteed to take effect until the session
restarts.

There are two ways to set it, with different guarantees:

1. **New, separate `claude` process (guaranteed to work).** Export it in
   the shell before starting the session:
   ```bash
   SHUNT_DEBUG_LOG=1 claude
   ```

2. **This skill, for the current project.** When invoked, always do this in
   order — report state first, then ask, regardless of how the user phrased
   the request:
   - Read `.claude/settings.local.json` in the project root if it exists
     (create it with `{}` if not — this file is per-user and gitignored,
     never `.claude/settings.json`, which is shared).
   - Determine current state from `env.SHUNT_DEBUG_LOG`: treat `1`, `true`,
     `TRUE`, `yes`, `YES` as **enabled**; anything else (unset, empty, `0`,
     `false`) as **disabled**.
   - Tell the user the current state plainly (e.g. "Debug logging is
     currently **enabled**" / "Debug logging is currently **disabled**").
   - Ask the user what to do next with `AskUserQuestion`, offering only the
     action(s) that make sense for that state:
     - If enabled: offer "Disable logging" (and, if useful, "Leave as is").
     - If disabled: offer "Enable logging" (and, if useful, "Leave as is").
     Do not infer the desired direction from the original wording and skip
     the question — always let the user pick, even if their request sounded
     like it already implied a direction.
   - Apply the choice (same mechanism `/toggle-hooks` uses for
     `SHUNT_HOOKS_DISABLED`):
     - Enable: merge in `{"env": {"SHUNT_DEBUG_LOG": "1"}}`, preserving any
       other keys already in the file.
     - Disable: remove the `SHUNT_DEBUG_LOG` key from `env` (delete the
       `env` object too if it becomes empty), preserving everything else.
     - Leave as is: make no changes.
   - Tell the user plainly: this file is read by Claude Code at session
     start, so the change won't reliably apply to the running session —
     restart Claude Code (start a new session) for it to take effect.

## When to use this skill

- The user wants to start or stop recording real delegate usage before or
  after checking `/usage-report`.
- The user asks whether `SHUNT_DEBUG_LOG` is on, or how to turn it on/off.

## When NOT to use this skill

- To read or summarize the log once it's enabled, use `/usage-report`
  instead — this skill only flips the switch.
