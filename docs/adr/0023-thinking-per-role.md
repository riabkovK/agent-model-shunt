# 0023: Thinking per role

## Status

Accepted

## Context

[ADR 0013](0013-thinking-off-by-default-per-model-opt-in.md) and
[ADR 0021](0021-thinking-options-apply-to-both-transports.md) give each model
one `thinking` flag. The roles want different things: bulk-read was measured on
`mac/qwen36` with the same recall and about 3x less time with thinking off,
while code-write may gain from thinking. With one flag per model the user had
to pick one state for both roles, or hand-write a provider-specific
`role_request_body`, which only works on the HTTP transport.

## Decision

- A model may carry an optional `role_thinking` object, role name to bool,
  e.g. `{"code-write": true}`. For a call in a role, `role_thinking[role]`
  wins over `thinking`. A role without an entry follows `thinking`. Without
  the field nothing changes.
- The options stay per model: `thinking_options` when the role's effective
  state is on, `thinking_off_options` when it is off.
- Both transports honor it. The HTTP transport picks the options by the call's
  role. For opencode, the bulk-reader and code-writer agent files of a model
  are materialized with their own role's state.
- CLI: `shunt-models thinking <id> on|off --role <role> [options-json]` and
  `shunt-models thinking <id> --role <role> --clear`. Without `--role` the
  command sets the model default as before and leaves `role_thinking` alone.
- Validation rejects a non-object, an unknown role and a non-bool value.
- Defaults do not change until code-write is measured with thinking on and
  off on real models.

## Consequences

- The dashboard line keeps `thinking=` as the model default and adds
  `thinking_roles=` with each role's effective state when an override exists.
- A model default changed without `--role` does not reach a role that has an
  override. `/model-config` says so when it applies.
