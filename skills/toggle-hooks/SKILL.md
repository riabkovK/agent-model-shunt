---
name: toggle-hooks
description: Turn this plugin's PreToolUse hooks (check-file-size, check-bash-read) on or off via the SHUNT_HOOKS_DISABLED environment variable, for A/B testing Claude reading large files directly versus delegating through bulk-read. Use when the user wants to compare behavior, token cost, or latency with and without the shunt hooks active.
---

# Toggle Hooks

Lets you switch the plugin's `check-file-size`/`check-bash-read` PreToolUse
hooks off and back on, so the same large-file read can be tried both ways:
blocked-and-delegated (hooks on, the normal behavior) versus read directly
into Claude's own context (hooks off). Useful for empirically comparing
token/latency cost against `evals/benchmark.sh`'s synthetic numbers on real
files and real tasks.

## How it works

Both hooks check `SHUNT_HOOKS_DISABLED` first, before any size logic: if it
is `1`, `true`, `TRUE`, `yes`, or `YES`, the hook immediately returns
`{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}`
without inspecting the file at all.

There are two ways to set it, with different guarantees:

1. **New, separate `claude` process (guaranteed to work).** Export it in
   the shell before starting the session you want to test:
   ```bash
   SHUNT_HOOKS_DISABLED=1 claude   # hooks off for this whole session
   ```
   This is the most reliable way to run a true A/B comparison: one session
   started with the variable set, one without.

2. **This skill, for the current session.** When invoked, do the
   following:
   - Read `.claude/settings.local.json` in the project root if it exists
     (create it with `{}` if not — this file is per-user and gitignored,
     never `.claude/settings.json`, which is shared).
   - To disable: merge in `{"env": {"SHUNT_HOOKS_DISABLED": "1"}}`,
     preserving any other keys already in the file.
   - To re-enable: remove the `SHUNT_HOOKS_DISABLED` key from `env` (delete
     the `env` object too if it becomes empty), preserving everything else.
   - If the user's request doesn't say which direction, ask or infer from
     context (e.g. "turn hooks off for testing" = disable, "turn them back
     on" = re-enable).
   - Tell the user plainly: this file is read by Claude Code at session
     start. If the hook's behavior doesn't change on the very next matching
     tool call, restart the session so the new environment is picked up —
     don't assume it always hot-reloads.

## When to use this skill

- The user wants to compare token/latency cost of delegated bulk-read
  against a direct Claude read of the same file (see `evals/benchmark.sh`
  for the equivalent synthetic-fixture comparison).
- The user is debugging whether the hooks or the delegation script itself
  is responsible for some unexpected behavior, and wants to isolate the
  hooks by turning them off.

## When NOT to use this skill

Don't disable the hooks as a way to work around a blocked read you actually
want blocked — if a file is genuinely too large to read directly, use the
`/bulk-reader` skill instead of turning the gate off.
