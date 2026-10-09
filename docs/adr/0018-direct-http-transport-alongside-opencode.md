# 0018: Direct HTTP transport alongside the OpenCode CLI, chosen per provider

## Status

Accepted. Supersedes [ADR 0002](0002-wrap-opencode-cli-not-http-client.md).

## Context

ADR 0002 wrapped `opencode run` for the MVP and named a direct HTTP client as
the later optimization. The MVP proved the delegation worth it, and the
remaining cost is process start: every call spawns `opencode`, which has a
large startup overhead before the model is even contacted. A raw `curl` to the
same endpoint is far faster.

## Decision

Calls go through a transport layer (`scripts/lib/transport.sh`). Every
transport yields the same normalized response file, so the external contract
(bulk-read stdout, the usage line on stderr, debug log fields) does not change.

- `http` (`scripts/lib/transport-http.sh`): one non-streaming POST to an
  OpenAI-compatible `/chat/completions` endpoint with `curl`. Only bash, jq and
  curl are needed, consistent with [ADR 0004](0004-bash-jq-implementation.md).
- `opencode`: the previous behavior, kept as a fallback for providers that are
  not OpenAI-compatible.

The transport is a per-provider `transport` field in `providers.json`. The
lookup is model id, then the provider (the part before the first `/`), then
that provider's `transport`. A model or provider with no entry means the
implicit `opencode`, so a registry written before this change keeps working
without migration. The `SHUNT_TRANSPORT` environment variable overrides the
lookup and exists for tests. An unknown transport name is an error.

`shunt-models --migrate-from-opencode` moves an existing OpenCode setup to
`http`. It is opt-in and never runs implicitly.

### Measured latency

2026-10-09, mac, model qwen36, `bulk-read` of a 316-line file, 3 runs each,
averages after the thinking fix from [ADR 0021](0021-thinking-options-apply-to-both-transports.md):

| Transport | Thinking off | Thinking on |
|---|---|---|
| opencode | 40.8s | 91.7s |
| http | 15.4s | 77.8s |

HTTP is about 2.6x faster without thinking. With thinking on, model time
dominates and the two are close.

## Consequences

- Delegated calls with thinking off drop from about 41s to about 15s on the
  measured setup.
- Two code paths now have to stay behaviorally equal. The normalized response
  format is the seam that keeps them so.
- Materialized agents ([ADR 0011](0011-model-registry-materialized-agents.md))
  are only needed for the `opencode` transport. The `http` transport reads the
  role prompt directly.
- Platforms: Linux, macOS and WSL. Native Windows is unsupported.
