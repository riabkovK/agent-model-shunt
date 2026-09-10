# 0008: Native `-f/--file` attachment over manual XML wrapping

## Status

Accepted

## Context

shunt's `scripts/bulk-read` manually wraps each file's contents into an XML
tag inside a single message payload, and guards against exceeding
`SHUNT_MAX_PAYLOAD_BYTES` (ARG_MAX-aware, since Portal CLI takes the
payload as a command-line argument). This exists because Portal CLI has no
native concept of "attach this file."

`opencode run --help` (checked locally, not just docs) shows `-f/--file
<file>` as a first-class, repeatable flag for attaching files to a run.

## Decision

Use `opencode run`'s native `-f/--file` flag to attach files directly,
instead of porting shunt's manual XML-wrapping-plus-payload-size-guard
approach.

## Consequences

- `scripts/lib/opencode.sh` and `scripts/bulk-read` are simpler than
  shunt's equivalents: no XML wrapping, no `SHUNT_MAX_PAYLOAD_BYTES`
  environment variable, no ARG_MAX detection logic.
- File-size limits, if any, are OpenCode's own concern, not something this
  project needs to compute or enforce.
- This is a design decision, not one of the explicitly grilled questions;
  it was made unilaterally during CLI verification because the native flag
  is a strict simplification with no behavior tradeoff, and is recorded
  here for traceability rather than because it required a user decision.
