# 0016: `code-write` shares the model registry via per-model roles, not a second registry

## Status

Accepted

## Context

`code-write` needs its own pool of candidate delegate models, with the same
priority-order-plus-failover shape `bulk-read` already has (
[ADR 0011](0011-model-registry-materialized-agents.md),
[ADR 0012](0012-circuit-breaker-separate-from-model-selection.md)). Standing
up a second registry file would duplicate `models.json`'s add/remove/reorder/
enable/disable machinery and give the user two places to manage what is
conceptually the same list of models.

## Decision

`models.json` entries gain an optional `roles` array (e.g.
`["bulk-read","code-write"]`). A missing `roles` field means the model has
every role, so every registry written before this change keeps working with
no migration. There is still one `active` pointer and one priority order
shared by all roles.

Candidates for a role are computed as: the `active` model first, if it is
enabled and has the role, then the remaining enabled models with the role in
their existing array order, deduplicated, all in a single `jq` pass over the
registry (`shunt_models_candidates <role>`). Measured at about 3.8ms per
registry call, dominated by process spawn, so adding the role filter costs
nothing extra worth optimizing. No candidate for a role is a clear error for
`code-write` (nothing to delegate to) and "do not redirect, let the read
through" for `bulk-read` (same behavior an empty or fully-disabled registry
already has, per [ADR 0014](0014-enabled-flag-and-empty-registry-means-no-redirect.md)).

Each model with the `code-write` role gets a second materialized OpenCode
agent, `shunt-code-writer-<slug>`, alongside its existing `bulk-reader.md`-shaped
one if it also has that role: all tools off, low temperature, and the
`SHUNT-NOTES`/`SHUNT-CODE` protocol from
[ADR 0015](0015-code-write-create-only-and-tag-protocol.md) baked into its
prompt. `scripts/shunt-models roles` edits the `roles` field; `/model-config`
was updated to surface it.

The circuit breaker tracks failures per role, not per model: a `code-write`
failure and a `bulk-read` failure on the same underlying model are counted
separately, keyed `<model-id>#code-write` vs. the plain model id (no
migration needed, since the plain key already existed).

The accepted trade-off: a model cannot be "first choice for reading, second
choice for writing" while both stay listed as fallbacks for both roles,
since there is one shared priority order, not one per role. The workaround
is narrowing a model's `roles` to just the role where its position matters.
A per-role `active` pointer (e.g. `active_code_write`) is a possible future
addition and does not require a migration when it's added, since the field
would simply be absent from every registry written before it exists.

## Consequences

- Adding `code-write` support required no new registry file, no new
  enable/disable/remove commands, and no second failover implementation:
  `shunt_invoke_with_failover` and `scripts/lib/breaker.sh` are reused
  as-is, parameterized by role.
- A user who wants asymmetric priority between reading and writing has to
  split their model list by `roles` rather than express it directly; this
  is a known, accepted limitation, not an oversight.
- The materialized-agent-per-model approach from ADR 0011 now produces up to
  two agent files per model (one per role it holds) instead of one; cleanup
  on `remove` deletes both.
</content>
