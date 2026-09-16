# 0010: Defer host-adapter module extraction until a second host is built

## Status

Accepted

## Context

[ADR 0009](0009-multi-host-scope-shift.md) shifted the project's framing
from "Claude Code only" to "Claude Code first, other hosts planned," but
left the code structure untouched: everything still lives flat, with no
separation between logic that is genuinely host-agnostic (the OpenCode
delegation itself: `scripts/lib/opencode.sh`, `scripts/bulk-read`) and
logic that is Claude-Code-specific by construction
(`.claude-plugin/plugin.json`, `hooks/hooks.json`, the `PreToolUse` hook
contract).

The user asked whether 0009 should have required splitting this into a
common core plus a per-host module now, so that adding Codex later is a
matter of adding a module rather than reworking shared code. Grilled out
with the user on 2026-09-16.

## Decision

Do not extract a host-adapter module yet. Keep the current flat structure
until Codex (or another host) support is an actual, active piece of work,
not just a planned one. At that point, design the common/host-specific
split as part of that work, informed by what a real second host actually
needs, rather than guessing the boundary now from a single data point.

## Consequences

- No structural change from this ADR: file layout stays as it is today.
- The common/host-specific boundary is unvalidated speculation until a
  second host exists; extracting a module now risks drawing that boundary
  in the wrong place and having to redo it once Codex's actual
  requirements are known.
- When Codex (or another host) work starts, that work must include its own
  design pass for the module split, not assume today's file layout
  generalizes as-is.
- [ADR 0009](0009-multi-host-scope-shift.md) remains accurate as written:
  its "Partial" implementation status (naming/framing done, adapter layer
  not built) is the intended state until the trigger condition above is
  met, not an open gap to close independently.
