# 0013: Delegate model "thinking" mode off by default, per-model opt-in with raw provider options

## Status

Accepted

## Context

Some delegate models support a "thinking"/extended-reasoning mode.
`scripts/bulk-read` is a summarize/extract task over an attached file, not
a task that benefits from deep multi-step reasoning, and reasoning tokens
cost real time and money per call regardless of whether they change the
answer. Added to scope 2026-09-16 per user request, alongside the rest of
`docs/TODO.md`'s multi-model plan.

The harder question was how to represent "on" once a user wants it for a
specific model: providers expose reasoning controls under completely
different shapes (an Anthropic-style `thinking: {type, budget_tokens}`
object vs. an OpenAI-style `reasoningEffort: "high"` string, and others
neither of these). Hardcoding one provider's shape into
`shunt_models_materialize_agent` would silently do nothing (or error) for
every other provider.

## Decision

`thinking` defaults to `false` for every model added to the registry
(`scripts/shunt-models add`), and `shunt_models_materialize_agent` emits no
reasoning-related frontmatter at all when it's off - not an explicit
"off" field, just omission, since that's the one behavior every provider
is guaranteed to interpret as "don't force reasoning on."

Turning it on is per-model, never global, via
`scripts/shunt-models thinking <id> on '<options-json>'`. The caller
supplies the provider's own reasoning option(s) as a flat JSON object;
`shunt_models_materialize_agent` merges those key/value pairs verbatim into
the generated agent's frontmatter (OpenCode's `AgentConfig` accepts
arbitrary provider-specific top-level keys). shunt itself never
interprets or validates the *meaning* of those keys - only that the value
supplied is syntactically valid JSON. The `/model-config` skill is
responsible for asking a plain yes/no question before turning it on for a
given model, and for telling the user honestly when it doesn't know their
provider's exact option name rather than guessing one that might silently
no-op.

`scripts/shunt-models thinking <id> off` clears both the flag and any
stored options and re-materializes the agent immediately.

## Consequences

- New models never pay reasoning-token cost by accident; a user must
  explicitly opt in per model and knows (or is told to go find) the
  option their specific provider needs.
- shunt stays provider-agnostic: adding support for a new provider's
  reasoning knob never requires a code change, only the user passing the
  right JSON at `thinking on` time.
- If a provider's reasoning mode can't be disabled by omitting fields (i.e.
  it reasons unconditionally with no off-switch), shunt's off-by-default
  design can't fully suppress it - this ADR controls what shunt writes into
  the agent config, not what a given provider does with an agent that has
  no reasoning fields set at all.
- Confirmed by a live test on 2026-09-17: shunt always sends its
  on/off/options intent to the provider through the agent's frontmatter
  fields, exactly as this ADR describes. Whether that intent is actually
  honored depends on whether OpenCode's provider adapter forwards those
  fields into the underlying API call, and that varies per provider/host.
  Tested against OpenCode 1.18.18 with a `provider.mac` entry using
  `@ai-sdk/openai-compatible` in front of a local Ollama server
  (`qwen36`, a hybrid-reasoning model that reasons unless told not to):
  neither omitting reasoning fields nor adding a manually-supplied
  `think: true`/`think: false` key changed the model's behavior at all -
  the model kept reasoning server-side either way (confirmed via wall-clock
  time and Ollama's own `message.reasoning` field on its native `/api/chat`
  endpoint, which does honor `think: false` when called directly). OpenCode's
  transcript reported `tokens.reasoning: 0` regardless, because this
  provider adapter doesn't surface Ollama's `reasoning` field as counted
  tokens - not because reasoning was actually suppressed. So for at least
  this provider/host combination, shunt's `thinking off` has no effect: the
  model reasons on its own default regardless of what shunt sends. This is a
  known limitation, not a bug to silently work around; if a given
  provider/host combination doesn't honor these fields, the model falls back
  to its own default reasoning behavior, and shunt has no way to detect or
  report that mismatch from its side of the call.
