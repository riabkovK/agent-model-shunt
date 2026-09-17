---
name: model-config
description: Dashboard and editor for the shunt-owned delegate model registry (which models are configured, which is active, per-model retry/failover behavior) and its retry settings. Use when the user wants to add/remove/reorder delegate models, switch the active one, turn a model's thinking mode on/off, or tune how shunt reacts to a model repeatedly failing.
---

# Model Config

Single entry point for both halves of shunt's delegate-model configuration:
the model registry (`scripts/shunt-models`, `~/.config/agent-model-shunt/models.json`)
and the retry/failover behavior around a failing model (`scripts/shunt-breaker-config`,
`~/.config/agent-model-shunt/breaker-config.json`, internally called the
"circuit breaker" — see Terminology below). Always drive both through their
CLI, never by hand-editing either JSON file directly.

## No-argument dashboard

When invoked with no specific request, show the model registry first
(`scripts/shunt-models status`, or the legacy-mode message it prints if no
registry exists yet), then ask what the user wants to do — add/remove/
reorder/activate a model, or something else.

**Do not show circuit breaker details by default.** Most users don't know
what a circuit breaker is and don't need to. After the model list, ask a
single plain-language opt-in question, e.g.:

> Хотите настроить, что происходит, если одна из моделей перестаёт
> отвечать (сколько раз пробовать и когда переключаться на другую)?

or in English:

> Want to configure what happens when one of your models stops responding
> (how many retries before switching, and when to try it again)?

Only run `scripts/shunt-breaker-config show` and surface threshold/cooldown
details after the user says yes to that question. If they say no, stop
there — don't mention "circuit breaker" terminology at all unless they
bring it up first.

## Terminology

Internally (code, tests, env vars) this is called a "circuit breaker" —
that term is fine in explanations once the user has opted in, but don't
lead with it. Prefer describing the *behavior* first: "how many failed
attempts before shunt stops using a model for a while, and how long before
it tries that model again."

## Editing the model registry

Drive `scripts/shunt-models`:

```bash
scripts/shunt-models add <provider/model>       # also materializes its OpenCode agent
scripts/shunt-models remove <provider/model>
scripts/shunt-models reorder <provider/model> <1-based position>
scripts/shunt-models activate <provider/model>
scripts/shunt-models list
scripts/shunt-models status                      # id, agent, thinking flag, active marker
scripts/shunt-models sync                         # re-materialize all agent files
```

`add` requires the model's provider to already exist in the OpenCode
config's `provider` block (`$SHUNT_OPENCODE_CONFIG_HOME/opencode.json` or
`~/.config/opencode/opencode.json`) — if it's missing, the command fails
with a clear message rather than materializing an agent that can't run.

For a model's thinking/extended-reasoning flag (off by default per
`docs/TODO.md`'s design), there is currently no dedicated `shunt-models`
subcommand; report this as not yet implemented if asked, rather than
hand-editing `models.json`.

## Editing retry/failover behavior (circuit breaker), once opted in

Drive `scripts/shunt-breaker-config`:

```bash
scripts/shunt-breaker-config show                  # effective values + per-model status
scripts/shunt-breaker-config set threshold <N>      # positive integer: consecutive failures before pausing a model
scripts/shunt-breaker-config set cooldown <N>       # non-negative integer, seconds, before retrying a paused model
scripts/shunt-breaker-config disable                # presets an unreachable threshold; never pauses a model
scripts/shunt-breaker-config reset                  # deletes the config file, restores hardcoded defaults (3 / 300s)
```

- `show`'s output always includes numeric `threshold=`/`cooldown_seconds=`
  lines (useful for debugging) — when presenting this to the user after
  their opt-in, it's fine to state the actual numbers, since they've
  already asked to see them.
- If `show`'s output contains "not applicable" (no models registry
  configured yet — legacy single-agent mode), tell the user plainly that
  this doesn't apply yet because no delegate models are configured, and
  skip showing threshold/cooldown numbers — they'd be misleading in a mode
  where the breaker never actually engages.
- Present each value annotated with its default inline, e.g. "Порог: 5 (по
  умолчанию 3)" / "Threshold: 5 (default: 3)" — there is no stored "was
  this overridden" flag; `show`'s `(default: N)` suffix is a live
  comparison against the hardcoded constant, not persisted state.
- Validation (non-integer, threshold < 1, cooldown < 0) happens inside
  `shunt-breaker-config` itself — surface its error message rather than
  pre-validating in the skill.
- "Turn the breaker off" maps to `disable`, not a new flag — it's an
  extreme-value preset on the same two-field schema, not a new state in
  the JSON or in `scripts/lib/breaker.sh`'s branching logic.

## Precedence, for context if the user asks how a value took effect

Hardcoded default (3 failures / 300s) → `breaker-config.json` (if present)
→ `SHUNT_BREAKER_THRESHOLD`/`SHUNT_BREAKER_COOLDOWN_SECONDS` env vars,
which remain the top override for a single session or test run.

## When NOT to use this skill

- To delegate an actual file read, use `/bulk-reader` instead — this skill
  only edits configuration, never runs a delegated call itself.
- To read real per-call usage/cost, use `/usage-report` instead.
