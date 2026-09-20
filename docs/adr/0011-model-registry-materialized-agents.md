# 0011: Multi-model registry with materialized agent files, not dynamic agent generation

## Status

Accepted

## Context

[ADR 0005](0005-no-custom-mode-registry.md) decided against a custom mode
registry for the MVP, addressing OpenCode agents directly by name. That
held while shunt was pinned to exactly one hand-written agent
(`SHUNT_BULK_READER_AGENT`). Letting shunt rotate across several delegate
models (grilled out with the user on 2026-09-15/16, planned on
`phase/multi-model-support`) needs *some* source of truth for which models
exist, in what priority order, and which OpenCode agent each one maps to.
That's a registry in substance even if not in the form ADR 0005 rejected.

Two ways to get from a registered model id to a runnable OpenCode agent
were considered: generate the agent file fresh on every `scripts/bulk-read`
call, or materialize it once when the model is added/edited and reuse it.

## Decision

Add a shunt-owned registry file (`~/.config/agent-model-shunt/models.json`)
listing `provider/model` ids in priority order, with an `active` pointer.
Editing it (`scripts/shunt-models add/remove/reorder/activate/thinking`) is
the only way to change it - never hand-edited, matching the model-config
skill's own rule for the circuit breaker config (see [ADR
0012](0012-circuit-breaker-separate-from-model-selection.md)).

Each registered model gets an OpenCode agent file materialized into
`~/.config/agent-model-shunt/agents/` **once, at edit time**, not
regenerated on every delegated call. `scripts/lib/opencode.sh` picks a
candidate from the registry, resolves its already-materialized agent name,
and runs it exactly as it already did for the single hand-written
`bulk-reader` agent - the failover/isolation code path doesn't need to know
whether an agent was hand-written or materialized.

When no registry file exists, every `scripts/lib/models.sh` function fails
closed (`shunt_models_available` returns non-zero) and callers fall back to
the pre-existing single-agent path untouched. A user who never adopts
multi-model support sees no behavior change.

## Consequences

- One extra file write per registry edit (materialize), not per delegated
  call - keeps `scripts/bulk-read`'s hot path identical in cost to the
  single-agent case regardless of how many models are registered.
- The registry is a second source of truth alongside the materialized
  agent files themselves; `scripts/shunt-models sync` re-materializes all
  of them from the registry if they ever drift (e.g. a user hand-edits an
  agent file despite being told not to).
- Legacy single-agent installs (no `models.json`) are unaffected; this is
  additive, not a breaking change to ADR 0005's original agents-addressed-
  by-name model.
