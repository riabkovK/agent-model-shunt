# 0009: Scope shift from Claude Code only to Claude Code first, other hosts planned

## Status

Accepted

## Context

[ADR 0003](0003-claude-code-only-scope.md) scoped the MVP to Claude Code
only, to keep the surface area small while validating whether the
delegation concept works at all. That validation has since happened: the
plugin works, and Codex support is now a real near-term plan rather than
speculative future-proofing.

The project's old name, `cc-model-shunt`, encoded the Claude-Code-only
scope directly into its identity. Keeping that name while planning Codex
support would mean shipping a name that actively misdescribes the
project's direction. Grilled out with the user on 2026-09-15/16.

## Decision

Shift the project's scope framing from "Claude Code only" to "Claude Code
first, other agent hosts (Codex, etc.) planned," and rename the project
from `cc-model-shunt` to `agent-model-shunt` to match. This does not revoke
or edit ADR 0003: its decision (Claude Code only for MVP) and its
consequence (the plugin format is Claude-Code-specific by design; a real
adapter layer is needed for other hosts) both still hold as a description
of the current implementation. ADR 0003 remains `Accepted`; this ADR
supersedes only its scope framing, not its technical consequence.

## Consequences

- The project name, repository, cache paths, and top-line descriptions
  (`README.md`, `plugin.json`, `marketplace.json`) no longer imply a single
  host.
- `.claude-plugin/plugin.json` and `hooks/hooks.json` remain
  Claude-Code-specific today; adding Codex (or another host) support still
  requires the adapter layer ADR 0003 already anticipated. This ADR records
  the intent, not the implementation — no adapter layer exists yet.
- Future host-specific work should treat "Claude Code" as the first
  implemented target, not the only one, when naming things or writing
  docs.
