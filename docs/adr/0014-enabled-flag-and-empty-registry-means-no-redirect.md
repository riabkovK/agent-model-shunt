# 0014: Per-model enabled flag, and an empty registry means no read redirection

## Status

Accepted

## Context

Before this change a model could only be in the registry or not. There was
no way to take one out of rotation temporarily, and the registry refused to
hold zero models, so removing the last one was impossible. That second
rule also conflicted with the hook's purpose: the file-size hook exists to
send large reads to a delegate model, and with no delegate model there is
nothing to send them to.

## Decision

Each registry entry carries an `enabled` boolean. A missing field counts as
enabled, so registries written before this change keep working unchanged.
`scripts/shunt-models disable|enable <id>` flips it and nothing else: the
entry keeps its position, agent file, thinking settings and `active` marker.

`shunt_models_candidates` filters disabled entries out in the same `jq` pass
that already builds the candidate list. A disabled model therefore never
reaches the circuit breaker check or the delegate call, so the flag adds no
per-call cost and no breaker state is read or written for it. A disabled
`active` model is skipped silently and becomes active again on `enable`.
`activate` refuses a disabled model, since that combination could never take
effect.

An empty `models` array is now a valid registry. `remove` may delete the
last model. When the candidate list is empty (no models, or all disabled),
`hooks/check-file-size` allows the direct `Read` through, the same outcome
already used when every candidate's breaker is open. `scripts/bulk-read`
fails with a message saying no delegate model is enabled, rather than
falling back to the legacy single agent: a registry file that exists always
means registry mode, and only its absence means legacy mode.

## Consequences

- A user can pause a flaky or expensive model with `disable` and restore it
  with `enable`, without losing its position or settings.
- Removing every model is a supported way to switch shunt's redirection off
  without touching hook configuration. Deleting `models.json` is a different
  action: it returns to legacy single-agent mode, which still redirects.
- `remove` also deletes the model's agent file and its breaker state, so a
  later re-add starts clean.
- Three states now look alike from Claude's side (no registry entries, all
  disabled, all breakers open): each lets large reads through. They differ
  only in why, which `shunt-models status` reports for the first two.
