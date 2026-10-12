# 0021: Thinking options apply to both transports

## Status

Accepted

## Context

[ADR 0013](0013-thinking-off-by-default-per-model-opt-in.md) made thinking off
by default, controlled by the per-model `thinking` flag and the raw
`thinking_options` and `thinking_off_options` objects. Those options were
written for OpenCode (camelCase, e.g. `reasoningEffort`) and were applied only
to materialized agent files. The first `http` transport ignored them, so a model
with thinking off still thought, which is a bug and made the transports behave
differently.

## Decision

The `http` transport applies the same thinking options as `opencode`: the
`thinking_options` object when `thinking` is true, otherwise
`thinking_off_options`, with unset meaning no extra fields.

OpenCode camelCase names become snake_case body fields (`reasoningEffort`
becomes `reasoning_effort`). The request body is built by shallow merges where
the later one wins:

1. the converted thinking options,
2. the model's `request_body`,
3. the role's entry in `role_request_body`.

So a user can always override a thinking field by hand in `request_body`, and
`code-write` can differ from `bulk-read` through `role_request_body`. The
`model` and `messages` fields are always set by the transport and cannot be
replaced.

## Consequences

- Thinking on or off means the same on both transports, which the 2026-10-09
  latency numbers in [ADR 0018](0018-direct-http-transport-alongside-opencode.md)
  rely on.
- The name conversion is mechanical. A provider that expects a field name that
  is not the snake_case form of the OpenCode one needs it set in `request_body`.
