---
name: model-config
description: Dashboard and editor for the shunt-owned delegate model registry (which models are configured, which is active, which jobs each may do, per-model retry/failover behavior), its circuit-breaker retry settings, and the code-write self-fix loop's retry count. Use when the user wants to add/remove/reorder/disable/enable delegate models, switch the active one, limit a model to reading or writing (roles), turn a model's thinking mode on/off, tune how shunt reacts to a model repeatedly failing, or tune how many times code-write retries a failed generated file before falling back to Claude.
---

# Model Config

Single entry point for all of shunt's delegate-model configuration:
the model registry (`scripts/shunt-models`, `~/.config/agent-model-shunt/models.json`),
the retry/failover behavior around a failing model (`scripts/shunt-breaker-config`,
`~/.config/agent-model-shunt/breaker-config.json`, internally called the
"circuit breaker" — see Terminology below), and the code-write self-fix
loop's retry count (`scripts/shunt-codewrite-config`,
`~/.config/agent-model-shunt/code-write-self-fix-config.json`). Always drive all three
through their CLI, never by hand-editing any of the JSON files directly.

## No-argument dashboard

When invoked with no specific request, show the full status in one pass,
as two separate, clearly labeled blocks, then ask what the user wants to
do — add/remove/reorder/activate/disable a model, tune the breaker, or
something else.

1. **Model registry** (`scripts/shunt-models status`, or the legacy-mode
   message it prints if no registry exists yet). For every model, not just
   the active one, show: enabled/disabled, whether it's the active model,
   its roles, and its thinking-mode state (on/off, and whether off is an
   explicit stored setting — `thinking_off=set` — or just the unset
   default — `thinking_off=none`). Don't omit a model just because its
   thinking mode is off or it isn't active; the point of the dashboard is
   that every model's state is visible at a glance, e.g. as one row per
   model in a small table.
2. **Circuit breaker**: settings and per-model state
   (`scripts/shunt-breaker-config show`), shown right after the registry,
   not gated behind an opt-in question. Include the threshold and cooldown
   (each annotated with its default, see below) and every model's failure
   counters for both `bulk-read` and `code-write`. If `show`'s output says
   "not applicable" (no registry yet, legacy single-agent mode), say so
   plainly instead of printing numbers that wouldn't mean anything yet.
3. **Code-write self-fix loop**: the retry count
   (`scripts/shunt-codewrite-config show`), shown right after the circuit
   breaker block, also not gated behind an opt-in question — same
   "annotated with its default" treatment as the breaker's threshold and
   cooldown, e.g. "Повторные попытки self-fix: 1 (по умолчанию 1)" /
   "Self-fix retries: 1 (default: 1)". This setting is global, like the
   breaker's, not per-model: show it once regardless of how many models
   have the `code-write` role. If no model in the registry has that role
   yet, still show the value (it takes effect the moment a model gains the
   role) rather than omitting the block.

## Language

Present the whole dashboard, and every other reply from this skill, in the
language the user is writing in, not the raw CLI's language. The
underlying scripts always print English (`enabled`, `disabled`,
`active`, `failures=`, `open=`), so translate/label values instead of
pasting raw lines verbatim, e.g. "включена"/"отключена", "активна",
"выключен", "не на паузе". Match the user's language for the whole
reply, including any explanations, the same way as the rest of the
conversation — this skill has no separate language setting of its own.

## Terminology

Internally (code, tests, env vars) this is called a "circuit breaker" —
that term is fine once you're explaining what it does, but still lead with
the *behavior*, not the name: "how many failed attempts before shunt stops
using a model for a while, and how long before it tries that model again."

## Editing the model registry

Drive `scripts/shunt-models`:

```bash
scripts/shunt-models add <provider/model> [<role>[,<role>...]]   # roles default to both, also materializes its OpenCode agent files
scripts/shunt-models remove <provider/model>
scripts/shunt-models reorder <provider/model> <1-based position>
scripts/shunt-models activate <provider/model>
scripts/shunt-models disable <provider/model>    # keep it, but stop using it
scripts/shunt-models enable <provider/model>
scripts/shunt-models roles <provider/model> <role>[,<role>...]   # bulk-read, code-write
scripts/shunt-models list
scripts/shunt-models status                      # id, agent, enabled/disabled, thinking flag, thinking_off=set|none, roles, active marker, then the first choice
scripts/shunt-models sync                         # re-materialize all agent files (bulk-reader, and code-writer for models with that role)
```

`remove` also deletes that model's materialized agent files (bulk-reader and
code-writer) and its retry/failover
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
and `code-write` (generating new files, what `scripts/code-write` uses). A model
with no `roles` set has both,
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

### Adding a model with the `code-write` role: offer the self-fix loop settings

Whenever the roles just given to `add` (or a later `roles` call) include
`code-write`, follow up with a plain yes/no question: "Хотите настроить
параметры self-fix-цикла (сколько раз code-write пытается сам исправить
неудачную сборку/тест, прежде чем передать это вам)?" / "Want to configure
the self-fix loop's settings (how many times code-write retries a failed
build/test itself before handing it back to you)?" Ask this once per `add`
or `roles` call that grants the role, not on every dashboard view — the
no-argument dashboard already shows the current value passively (see above).

- No: do nothing further. The model uses whatever `self_fix_retries` value
  is already configured (global, not per-model — see below).
- Yes: show the current value from `scripts/shunt-codewrite-config show`,
  then offer the retry count as a choice (e.g. `AskUserQuestion` with a few
  common values like 0/1/2/3 plus free text), and apply it with
  `scripts/shunt-codewrite-config set self-fix-retries <n>`. Make clear
  before asking that this is a single global setting, not specific to the
  model just added: changing it here changes it for every model with the
  `code-write` role.

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
  `first choice:` line is the first choice for `bulk-read`. A second line,
  `code-write first choice:`, is the first choice for `code-write`, or says that
  no enabled model has that role (code-write is then unavailable and
  `scripts/code-write` stops with a clear error before calling any model).
- An invalid `roles` value in the registry (for example a hand-edit typo like
  `bulk_read`) makes the whole registry invalid, so shunt falls back to legacy
  single-agent mode. `status` and `list` then print the reason. Run
  `scripts/shunt-models roles <provider/model> <role>[,<role>...]` on the
  offending model to repair it.
- Each model with the `code-write` role gets a second materialized agent,
  `shunt-code-writer-<slug>`, next to its bulk-reader agent. It has every tool
  disabled and a low temperature, because `scripts/code-write` writes the file
  itself and the model only returns text. `add`, `sync`, `thinking` and `roles`
  keep it consistent with the registry: it is created when the role is present
  and deleted when the role is dropped. `roles` does not touch retry/failover
  state. After updating the plugin, run `scripts/shunt-models sync` once so
  registries written earlier get their code-writer agents, and so existing
  code-writer agents get the current reply protocol prompt (with its example
  reply).
- `code-write` keeps its own failure counter per model, separate from
  `bulk-read`'s. A model that keeps failing writes is paused for `code-write`
  only and stays usable for reading, and the other way round. `status` shows
  each model's code-write state on `code-write breaker <id>:` lines, and
  `scripts/shunt-breaker-config show` lists it as `<id> (code-write):` under the
  model's own line. Counters recorded before this split are the `bulk-read`
  ones, so nothing needs migrating, and `remove` clears both.

## Thinking/extended-reasoning, per model (off by default)

Delegate models that support a "thinking" mode have it off by default —
bulk-read is a summarize/extract task, not deep reasoning, and thinking
tokens cost time and money without a clear fidelity benefit. Never turn it
on unprompted; only in response to the user asking about a specific model.

```bash
scripts/shunt-models thinking <provider/model> on '<options-json>'
scripts/shunt-models thinking <provider/model> off
scripts/shunt-models thinking <provider/model> off '<off-options-json>'
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
- `off` without options clears the flag and any stored on-options, and
  keeps any stored off options. It re-materializes the agent with the off
  options if there are any, otherwise without reasoning fields.
- Either direction re-materializes that one model's agent file
  immediately, so no separate `sync` is needed. `scripts/shunt-models sync`
  regenerates every agent file from the registry, including the off options.

### Explicit off options (hybrid reasoning models)

Omitting the reasoning fields does not turn thinking off on a hybrid
reasoning model, which keeps reasoning on its own default. To really switch it
off, store the provider's own "off" option as a flat JSON object:

```bash
scripts/shunt-models thinking <provider/model> off '{"reasoningEffort":"none"}'
```

- Tested on Ollama and other `@ai-sdk/openai-compatible` providers:
  `reasoningEffort: none` in the agent frontmatter cut a qwen model from about
  7300 to about 4500 output tokens on a large file (280 s to 139 s), and let
  DeepSeek finish in 95 s where it had timed out at 300 s.
- This is provider dependent. Verify it per provider and per model: some
  servers ignore the parameter and some reject it with an error. If a model
  still reasons after this, or a call starts failing, clear it with
  `thinking <provider/model> off '{}'` and tell the user the provider does not
  support it. shunt cannot detect a provider silently ignoring the request.
- The off options apply to both the bulk-reader and the code-writer agent of
  that model, and only while thinking is off. `thinking <id> on ...` keeps
  them stored but renders the on-options instead.
- `off '<json>'` requires a JSON object. `off` with no JSON leaves the stored
  off options unchanged. `off '{}'` removes them. `status` shows
  `thinking_off=set` or `thinking_off=none` per model.
- Only set this when the user asks for it or when a model is measurably slow
  because it reasons. It is opt-in per model, never a global default.

## Editing retry/failover behavior (circuit breaker)

Drive `scripts/shunt-breaker-config`:

```bash
scripts/shunt-breaker-config show                  # effective values + per-model status
scripts/shunt-breaker-config set threshold <N>      # positive integer: consecutive failures before pausing a model
scripts/shunt-breaker-config set cooldown <N>       # non-negative integer, seconds, before retrying a paused model
scripts/shunt-breaker-config disable                # presets an unreachable threshold; never pauses a model
scripts/shunt-breaker-config reset                  # deletes the config file, restores hardcoded defaults (3 / 300s)
```

- `show`'s output always includes numeric `threshold=`/`cooldown_seconds=`
  lines (useful for debugging) — these are part of the default dashboard
  now, so always state the actual numbers, not just whether they're
  customized.
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

## Editing the code-write self-fix loop's retry count

Drive `scripts/shunt-codewrite-config`:

```bash
scripts/shunt-codewrite-config show                              # effective value
scripts/shunt-codewrite-config set self-fix-retries <N>           # non-negative integer; 0 disables the loop
scripts/shunt-codewrite-config reset                              # deletes the config file, restores the hardcoded default (1)
```

- This is a global setting, not per-model or per-role: it controls how many
  times `skills/code-writer/SKILL.md`'s orchestration re-calls `code-write`
  on a mechanical build/test failure, for any model with the `code-write`
  role, before falling back to Claude fixing the file by hand.
- Present the value annotated with its default, same convention as the
  breaker: "Повторные попытки self-fix: 2 (по умолчанию 1)" / "Self-fix
  retries: 2 (default: 1)".
- `0` is a valid, deliberate value: it means the first generation is never
  retried automatically, so any build/test failure goes straight to Claude.
  It is not an error and needs no separate `disable` subcommand.
- Validation (non-integer, negative) happens inside `shunt-codewrite-config`
  itself — surface its error message rather than pre-validating in the
  skill.
- This setting never touches the circuit breaker's threshold/cooldown or
  its per-model failure counters; the two are unrelated (see Terminology).

## Precedence, for context if the user asks how a value took effect

Circuit breaker: hardcoded default (3 failures / 300s) → `breaker-config.json`
(if present) → `SHUNT_BREAKER_THRESHOLD`/`SHUNT_BREAKER_COOLDOWN_SECONDS` env
vars, which remain the top override for a single session or test run.

Self-fix retry count: hardcoded default (1) → `code-write-self-fix-config.json`
(if present) → `SHUNT_CODE_WRITE_SELF_FIX_RETRIES` env var, same override relationship.

## When NOT to use this skill

- To delegate an actual file read, use `/bulk-reader` instead — this skill
  only edits configuration, never runs a delegated call itself.
- To read real per-call usage/cost, use `/usage-report` instead.
