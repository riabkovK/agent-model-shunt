---
name: model-config
description: Setup wizard, dashboard and editor for the shunt-owned delegate model registry (which models are configured, which is active, which jobs each may do, per-model retry/failover behavior), its HTTP providers and keys, its circuit-breaker retry settings, and the code-write self-fix loop's retry count. Use when the user wants to set up shunt for the first time, migrate from OpenCode, add/remove/reorder/disable/enable delegate models or providers, enter a key, switch the active one, limit a model to reading or writing (roles), turn a model's thinking mode on/off, tune how shunt reacts to a model repeatedly failing, or tune how many times code-write retries a failed generated file before falling back to Claude.
model: haiku
---

# Model Config

The single entry point for shunt's delegate-model configuration. Drive it
only through the CLIs, never by hand-editing the JSON files:

- `${CLAUDE_PLUGIN_ROOT}/scripts/shunt-models`: registry (`~/.config/agent-model-shunt/models.json`),
  providers and keys (`providers.json`), context, migration.
- `${CLAUDE_PLUGIN_ROOT}/scripts/shunt-breaker-config`: retry/failover behavior, the "circuit
  breaker" (`breaker-config.json`).
- `${CLAUDE_PLUGIN_ROOT}/scripts/shunt-codewrite-config`: the code-write self-fix retry count
  (`code-write-self-fix-config.json`).

The plugin root is `${CLAUDE_PLUGIN_ROOT}`. Paths like `scripts/shunt-models` in
`reference.md` are relative to it, so run them with that prefix.

The full per-command reference is in `reference.md` next to this file. Do not
read it up front. When the user picks an action, read only that action's
section (Grep for its heading, then Read with offset and limit).

## Hard rules

- Keys never go through chat or a command line. Store them only with
  `<plugin-root>/scripts/shunt-key-dialog <provider>` (Bash timeout above
  120 s, e.g. 150000 ms), or with the `!` fallback line it prints on exit
  code 5. `<plugin-root>` is the absolute path two directories above this
  file. If a user pastes a key into chat, tell them to rotate it.
- Never read a stored key back in any form: no keyring lookup, no length, no
  prefix, no comparison. Only a provider call checks a key.
- Never run `--migrate-from-opencode --apply` before a dry run was shown and
  the user said yes. Dry run and apply are never the same step.
- Never guess a context window. Run `detect-context`. If it fails, ask the
  user and store the answer with `set-context`.
- Never turn thinking on unprompted. It is opt-in per model.
- Surface the scripts' own validation errors instead of pre-validating.

## Language

Reply in the user's language, the whole reply, including explanations. The
scripts always print English (`enabled`, `open=true`, `key_present=no`).
Translate and label values instead of pasting raw lines, e.g.
"включена"/"отключена", "активна", "не на паузе". This skill has no language
setting of its own.

Internally the breaker is called a "circuit breaker". Lead with the
behavior: "how many failed attempts before shunt stops using a model for a
while, and how long before it tries that model again".

## Dashboard flow

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/shunt-models dashboard` once. Do not run `status`,
   `provider list`, `key status` or the `show` commands for the dashboard:
   this one call has all of it. The line format is in reference.md,
   "Dashboard details". Only read it if a line is unclear.
2. Branch on the last line, `setup: ...`:
   - `empty`, `opencode-importable` or `incomplete`: run the wizard below.
   - `ok`: render the dashboard.
3. Render compact tables, in the user's language:
   - Providers: name, transport, base_url, key type, key present.
   - Models, one row each, every model: enabled, active, roles, thinking
     (on/off, explicit off set or not), context window, oversize policy,
     transport.
   - Breaker: threshold and cooldown, each with its default, then per-model
     state for bulk-read and code-write. With `registry: missing` say the
     breaker does not apply yet instead of showing numbers.
   - Self-fix retries with its default. Show it even if no model writes code.
   - First choice for bulk-read and code-write.
   - Any `issue` lines, in plain words.
4. Always end with the action menu.

## Action menu

End every dashboard and every finished action with a short numbered menu of
what the user can do next, in their language. Offer only what fits the
current state, at most about 8 items. Use AskUserQuestion when the user must
pick among options. Candidates, with the reference.md section to read:

| Action | reference.md section |
|---|---|
| Add a provider | Providers and keys; Adding an HTTP model, in order |
| Enter or change a key | Providers and keys |
| Add a model | Roles, per model; Adding an HTTP model, in order |
| Migrate from OpenCode | Migrating providers from OpenCode |
| Change roles, order or the active model | Editing the model registry; Roles, per model |
| Enable, disable or remove a model | Editing the model registry |
| Thinking on/off, off options | Thinking/extended-reasoning |
| Extra request fields | Extra request fields |
| Context window, oversize policy | Context window and oversize policy |
| Breaker settings | Editing retry/failover behavior |
| Self-fix retries | Editing the code-write self-fix loop's retry count |

Put the fix for any `issue` line first. Offer "Migrate from OpenCode" only
when `importable=` is not `none`.

## First-run wizard

`setup: empty` (nothing configured). Say shunt is not set up yet, then guide:

1. Ask the provider name and base_url, and whether it needs a key. Offer key
   storage with AskUserQuestion: keyring (recommended if available), env
   variable, plaintext (last resort), none (local, e.g. Ollama).
2. `${CLAUDE_PLUGIN_ROOT}/scripts/shunt-models provider set <name> --transport http --base-url <url> --key <type>`.
3. For keyring or plaintext, run `shunt-key-dialog <name>` (see Hard rules)
   and say a password window is open. For env, ask the user to export the
   variable. Confirm with `key status <name>`.
4. Ask the model id, then its roles (multi-select, both recommended), then
   `add <name>/<model> [<roles>]`. If it has code-write, offer the self-fix
   settings once.
5. `detect-context <id> --write`. If it fails with exit code 3 and the
   message `auth failed ... re-enter the key through /model-config`, the key
   was rejected (401 or 403): reopen the key dialog once, then retry. For any
   other failure ask the user for the context window and run `set-context`.
6. Re-run `dashboard`, show a short done summary and the action menu.

If `opencode config=present` while `empty`, mention that models can also be
added to the registry first and then migrated.

`setup: opencode-importable` (registry models use OpenCode providers that the
migration can move to HTTP). Offer the migration: run the dry run, summarize
the plan per provider and per model, ask with AskUserQuestion, and only on yes
run `--apply --yes`. Then handle keys for providers left pending. Read
"Migrating providers from OpenCode" first. If the user declines, show the
dashboard and menu.

`setup: incomplete`. Name each `issue` in plain words and offer to fix just
that, one at a time: `key-missing` (key dialog), `context-missing`
(`detect-context --write`, else ask), `no-models` (add a model),
`no-bulk-read-model` (enable a model or give one the bulk-read role),
`registry-invalid` or `providers-invalid` (show the reason from `status` or
`provider list`, then repair with the CLI). Then show the dashboard and menu.

## When NOT to use this skill

- To delegate an actual file read, use `/bulk-reader`. This skill only edits
  configuration and never runs a delegated call.
- To read real per-call usage or cost, use `/usage-report`.
