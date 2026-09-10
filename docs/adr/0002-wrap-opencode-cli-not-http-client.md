# 0002: Wrap the OpenCode CLI, not a custom HTTP client, for MVP

## Status

Accepted

## Context

`shunt` talks to Portal CLI as a subprocess. We could either shell out to
the already-installed `opencode` CLI the same way, or write a direct HTTP
client against the user's OpenAI-compatible `bootsman` provider endpoint,
skipping OpenCode entirely.

A direct HTTP client would remove one layer of indirection and one
subprocess spawn, but before investing in that we need to know whether the
delegation approach (any approach) is actually worth it: does it reliably
produce usable answers, and does it save enough Claude tokens to matter.

## Decision

For MVP, wrap the `opencode run` CLI via shell-out, exactly mirroring
shunt's approach to Portal CLI. A direct HTTP client is an explicit later
phase, once the CLI-wrapped MVP has proven the concept.

The user confirmed this explicitly: "Сейчас делаем обертку над opencode
CLI, чтобы понять вообще рабостоспособность MVP и пользу от него. После
этого будем переходить на свой http клиент для оптимизации процесса."

## Consequences

- Faster to build: reuses OpenCode's existing provider config, agent
  system, and auth, none of which need to be reimplemented.
- Adds a CLI subprocess spawn (and OpenCode's own startup overhead) to
  every delegated call; this is acceptable for MVP validation but a target
  for the future HTTP-client phase.
- The `--format json` event schema this project depends on
  (`scripts/lib/opencode.sh`) is OpenCode's own and may change between
  OpenCode versions; a future HTTP client would instead depend on the
  provider's raw OpenAI-compatible API, which is more stable.
