---
name: model-config
description: Dashboard and editor for the shunt-owned delegate model registry (which models are configured, which is active, which jobs each may do, per-model retry/failover behavior) and its retry settings. Use when the user wants to add/remove/reorder/disable/enable delegate models, switch the active one, limit a model to reading or writing (roles), turn a model's thinking mode on/off, or tune how shunt reacts to a model repeatedly failing.
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
scripts/shunt-models add <provider/model> [<role>[,<role>...]]   # roles default to both, also materializes its OpenCode agent
scripts/shunt-models remove <provider/model>
scripts/shunt-models reorder <provider/model> <1-based position>
scripts/shunt-models activate <provider/model>
scripts/shunt-models disable <provider/model>    # keep it, but stop using it
scripts/shunt-models enable <provider/model>
scripts/shunt-models roles <provider/model> <role>[,<role>...]   # bulk-read, code-write
scripts/shunt-models list
scripts/shunt-models status                      # id, agent, enabled/disabled, thinking flag, roles, active marker, then the first choice
scripts/shunt-models sync                         # re-materialize all agent files
```

`remove` also deletes that model's materialized agent file and its retry/failover
state, so nothing stale is left behind and a later re-add starts clean. If the
removed model was the active one, `active` becomes unset and no other model is
promoted automatically. Removing the last model is allowed: the registry then
holds zero models, and shunt stops redirecting large reads (Claude reads files
directly again) until a model is added or enabled.

`disable` / `enable` are the reversible alternative to `remove`. A disabled
model stays in the registry with its position, agent file, thinking settings and
active marker, but is never tried for a call and never counts toward the
"is any model usable" check that lets reads through. It costs nothing per call,
because it is filtered out before any retry/failover state is looked at. A
disabled model cannot be made active until it is enabled. If every model is
disabled, the effect is the same as an empty registry. `status` marks a disabled
active model as `active (skipped, disabled)` and ends with a `first choice:` line
naming the model the next call tries first (or saying no model is enabled), so
report that line when the user asks which model is the default now. Prefer `disable` when the
user wants a model out of rotation for a while, and `remove` when they are done
with it.

`add` requires the model's provider to already exist in the OpenCode
config's `provider` block (`$SHUNT_OPENCODE_CONFIG_HOME/opencode.json` or
`~/.config/opencode/opencode.json`) — if it's missing, the command fails
with a clear message rather than materializing an agent that can't run.

## Roles, per model

Each model can be limited to the jobs it may do. There are two roles:
`bulk-read` (answering questions about large files, what `/bulk-reader` uses)
and `code-write` (generating new files, not yet used by any command, so setting
it has no effect today). A model with no `roles` set has both,
so registries written before roles existed keep working unchanged.

### Adding a model: let the user pick its roles

Before running `add`, ask which roles the new model should have, with the
`AskUserQuestion` tool as a multi-select (`multiSelect: true`), one option per
role: `bulk-read` and `code-write`. Both are the default, so label both options
"(Recommended)" and say in the question text that both are on unless the user
unticks one, for example: "Which jobs may this model do? Keep both unless you
want to limit it." The tool cannot pre-tick options, so treat the selection as
the roles to keep:

- Both selected: run `add <provider/model>` with no roles argument (same as
  passing both).
- One selected: run `add <provider/model> <that-role>`.
- Nothing selected: a model needs at least one role, so ask again instead of
  guessing.

Only ask when the user did not already name the roles in the request. If they
did ("add X for reading only"), pass those roles and skip the question.

```bash
scripts/shunt-models roles <provider/model> bulk-read              # reading only
scripts/shunt-models roles <provider/model> code-write             # writing only
scripts/shunt-models roles <provider/model> bulk-read,code-write   # both
```

- `roles` replaces the model's whole role list. Order is kept and duplicates
  are dropped. An empty list or an unknown role is refused and the registry is
  left as it was.
- There is one `active` pointer and one priority order for every role. For a
  given role, the candidates are the `active` model first (only if it is
  enabled and has that role), then the other enabled models that have the role,
  in registry order. A model that lacks the role is simply skipped for it and
  keeps its `active` marker.
- The role list is the only way to say "this model only reads" or "this model
  only writes". It cannot express "A first for reading, B first for writing"
  while both stay fallbacks for both jobs. If the user wants that, restrict each
  model to its role.
- If no enabled model has `bulk-read`, large reads are not redirected, exactly
  as with an empty registry, and `status` says so. `status` shows each model's
  effective roles (`roles=bulk-read,code-write` when none are set) and its
  `first choice:` line is the first choice for `bulk-read`.
- An invalid `roles` value in the registry (for example a hand-edit typo like
  `bulk_read`) makes the whole registry invalid, so shunt falls back to legacy
  single-agent mode. `status` and `list` then print the reason. Run
  `scripts/shunt-models roles <provider/model> <role>[,<role>...]` on the
  offending model to repair it.
- Changing roles only edits the registry. It does not touch agent files or
  retry/failover state.

## Thinking/extended-reasoning, per model (off by default)

Delegate models that support a "thinking" mode have it off by default —
bulk-read is a summarize/extract task, not deep reasoning, and thinking
tokens cost time and money without a clear fidelity benefit. Never turn it
on unprompted; only in response to the user asking about a specific model.

```bash
scripts/shunt-models thinking <provider/model> on '<options-json>'
scripts/shunt-models thinking <provider/model> off
```

- When a model is added, thinking is off and no reasoning-related
  frontmatter is written to its agent file at all.
- To turn it on for one model, ask a plain yes/no question first (never a
  global switch): "Include <model>'s extended-reasoning mode? It costs more
  time and tokens per call." Only proceed on yes.
- `on` requires the caller to also supply the provider's own reasoning
  option(s) as a flat JSON object, e.g. `'{"reasoningEffort":"high"}'` for
  an OpenAI-style provider or whatever key/value the user's provider
  expects — shunt doesn't hardcode one provider's shape, it merges these
  keys verbatim into the agent's frontmatter. If the user doesn't know
  their provider's exact option name, say so plainly and ask them to check
  `opencode models <provider>` or their provider's docs rather than
  guessing a key that might silently do nothing.
- `off` clears both the flag and any stored options and re-materializes the
  agent without reasoning fields.
- Either direction re-materializes that one model's agent file
  immediately — no separate `sync` needed.
- shunt always sends the on/off/options intent to the provider through the
  agent's frontmatter. Whether it's actually honored depends on whether that
  provider/host forwards those fields into its API call — confirmed *not* to
  work on OpenCode 1.18.18 with a `@ai-sdk/openai-compatible` provider in
  front of Ollama, where a hybrid-reasoning model kept reasoning on its own
  default regardless of `thinking off`. Tell the user this plainly if they
  ask why a model still seems to be reasoning after turning it off: shunt
  can't detect or fix a provider silently ignoring its request.

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
