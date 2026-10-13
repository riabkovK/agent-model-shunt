# 0019: API key storage: keyring, env var, plaintext or none, never in argv

## Status

Accepted

## Context

The `http` transport ([ADR 0018](0018-direct-http-transport-alongside-opencode.md))
needs an API key per provider, which OpenCode used to hold. A key in `argv` is
visible to every local user via `ps`, and a key in a log or in chat is leaked
for good. The plugin runs on Linux, macOS and WSL, and these have different
secret stores.

## Decision

Each provider in `providers.json` has `key.type`, one of:

- `keyring`: the key lives in the OS keyring. Backends are `secret-tool`
  (Linux), `security` (macOS) and `kwallet-query` (KDE). The first one found is
  used. Under WSL no keyring is usable, so none is offered.
- `env`: `key.ref` holds the name of an environment variable, and the key is
  read from it at call time.
- `plaintext`: the key is stored in `providers.json`, which is written with mode
  600. Setting it prints a warning that a keyring or env var is preferable.
- `none`: no `Authorization` header is sent, for local endpoints without auth.

Rules that hold for every type:

- A key is entered only through an interactive `shunt-models key set
  <provider>` (silent `read`). It is never passed as an argument, never logged,
  and never typed into the chat.
- For the request, the `Authorization` header goes into a mode 0600 temp file
  handed to `curl` as `-H @file`, not into argv. A key containing a line break is
  refused so it cannot add extra headers. Redirects are never followed, so the
  header cannot be replayed to another host.
  Update: since [ADR 0022](0022-python-core-port.md) the header is built in the
  Python process and sent with `http.client`. There is no temp file and no curl.
- A 401 or 403 is a key problem, not the model's fault. It is not counted
  against the circuit breaker ([ADR 0012](0012-circuit-breaker-separate-from-model-selection.md)),
  and stderr hints at fixing the key.

## Consequences

- The strongest option on each platform is the keyring, then an env var.
  Plaintext is available because WSL has no keyring, and is flagged as weaker.
- Known limitation: the macOS `security add-generic-password` has no stdin
  mode, so during `key set` the key is briefly visible in that process's argv.
  An `env` key avoids this on macOS.
- `pass` is not supported.
