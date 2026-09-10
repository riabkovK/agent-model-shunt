# 0006: MVP scope is bulk-read only

## Status

Accepted

## Context

shunt ships two scenarios: `bulk-read` (delegate reading/summarizing a
large file) and `code-write` (delegate boilerplate generation). Building
both at once doubles the surface to validate before knowing whether the
concept pays off at all.

## Decision

MVP implements `bulk-read` only. `code-write` (and its hook, script, and
skill) is an explicit later phase, added once `bulk-read` has proven the
concept works and saves tokens.

## Consequences

- Smaller MVP, faster to ship and validate end-to-end.
- The `hooks/check-file-size` and `hooks/check-bash-read` hooks are written
  now (they gate the `bulk-read` path), but no hook gates boilerplate
  generation yet.
- `scripts/lib/opencode.sh` is written generically enough (an `agent`
  parameter, not hardcoded to `bulk-reader`) that adding `code-write` later
  should mostly mean a new script and a new OpenCode agent, not a rewrite
  of the shared library.
