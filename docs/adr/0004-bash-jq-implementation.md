# 0004: Bash + jq implementation

## Status

Accepted

## Context

shunt's hooks and scripts are plain Bash + jq, invoked directly as
PreToolUse commands and standalone CLI scripts. Alternatives considered:
Python or TypeScript/Node, which would add a runtime dependency and a
build/packaging step that Claude Code plugins don't otherwise need.

## Decision

Implement all hooks and scripts in Bash + jq, mirroring shunt's approach
exactly.

## Consequences

- No extra runtime dependency beyond `bash`, `jq`, and `opencode` (the
  latter is already required for the project to function at all).
- Hook startup latency stays minimal, since PreToolUse hooks run
  synchronously on every matching tool call.
- Bash's weaker error handling and string processing compared to Python is
  an accepted tradeoff, consistent with the pattern already proven in
  shunt.
