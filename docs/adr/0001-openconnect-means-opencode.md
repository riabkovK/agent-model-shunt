# 0001: "openconnect" means OpenCode

## Status

Accepted

## Context

The original request said models should register "similarly to
openconnect." This is ambiguous: `openconnect` is the name of an existing
VPN client, which does not fit a context about registering LLM models. The
plausible alternative is [OpenCode](https://opencode.ai), a coding CLI with
its own provider/model registration system (`opencode.json`,
`@ai-sdk/openai-compatible`-style provider packages) and its own agent
system, already installed and configured on the user's machine with a
custom `bootsman` provider.

## Decision

Treat "openconnect" as a reference to OpenCode. This was confirmed
explicitly by the user during grilling ("Это OpenCode (opencode.ai)").

## Consequences

All model registration in this project happens through OpenCode's own
`opencode.json` provider config and `opencode agent` system, not through a
project-specific registry. See [0005](0005-no-custom-mode-registry.md).
