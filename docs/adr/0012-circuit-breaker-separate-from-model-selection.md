# 0012: Circuit breaker on consecutive failures only, separate from model selection, no latency racing

## Status

Accepted

## Context

Once shunt could rotate across several delegate models ([ADR
0011](0011-model-registry-materialized-agents.md)), a model that starts
erroring or timing out needed some way to be skipped automatically instead
of failing every call until a human notices and reorders/removes it.
Grilled out with the user on 2026-09-15/16; the user explicitly asked that
its own settings be configurable through a separate skill, but with an
optimal default so most users never need to touch it.

Two extra capabilities were considered and explicitly ruled out for v1:
measuring response time and opening the breaker on slowness, and racing
multiple candidate models concurrently for the fastest response. Both add
real complexity (latency baselines per model, concurrent-call bookkeeping,
partial-result handling) for a benefit the MVP doesn't need - bulk-read is
not latency-sensitive enough to justify it, and racing multiplies delegate
API spend for marginal gain.

## Decision

A circuit breaker, scoped only to failures (errors/timeouts):
`SHUNT_BREAKER_THRESHOLD` (default 3) consecutive failures on a model opens
its breaker for `SHUNT_BREAKER_COOLDOWN_SECONDS` (default 300s), after
which it's retried automatically on the next call that reaches it in
priority order. State (per-model failure counts, cooldown timestamps) is
persisted to `SHUNT_BREAKER_STATE_FILE`, since every delegated call is its
own short-lived `opencode run` process with no shared memory between calls.

The breaker is a distinct concern from model selection/priority
(`models.json`, ADR 0011) and is configured separately
(`scripts/shunt-breaker-config`, `breaker-config.json`), with its own
precedence chain: hardcoded default -> config file -> env vars
(`SHUNT_BREAKER_THRESHOLD`/`SHUNT_BREAKER_COOLDOWN_SECONDS`) as the
top-of-session override. The `/model-config` skill gates showing any of
this behind an explicit plain-language opt-in question - most users don't
know what a circuit breaker is and the defaults are meant to just work.

No response-time measurement and no racing multiple models concurrently:
explicitly out of scope for v1, per the grilling session.

## Consequences

- Failing delegate calls degrade gracefully to the next registered model
  instead of hard-failing the whole `scripts/bulk-read` call, as long as at
  least one candidate's breaker is closed.
- If every registered model's breaker is open at once,
  `hooks/check-file-size` allows the direct `Read` through instead of
  denying it (see `docs/TODO.md`'s Breaker exhaustion behavior note) -
  denying would strand Claude with no usable path forward.
- A model that's merely slow, not failing, is never paused by this design;
  if latency-based circuit-breaking is wanted later, it needs its own
  design pass and its own ADR, not a silent extension of this one.
- Racing candidates concurrently remains unimplemented; if wanted later, it
  changes `shunt_invoke_with_failover`'s sequential-try loop materially and
  needs its own ADR.
