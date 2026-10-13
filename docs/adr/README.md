# Architecture Decision Records

This directory records the key decisions made while designing
`agent-model-shunt`, an analog of `spotify/portal-ai-plugins`' `shunt` plugin
that routes delegated work to user-owned custom models via OpenCode instead
of Spotify's Portal CLI and AiKA models.

`Implemented` tracks whether the current code reflects the decision, separately from
`Status` (the decision's own standing: Accepted/Superseded). A `Partial` ADR names
exactly what's still missing in its own Consequences section; see that ADR for detail
rather than duplicating it here.

| ADR | Title | Status | Implemented |
|---|---|---|---|
| [0002](0002-wrap-opencode-cli-not-http-client.md) | Wrap the OpenCode CLI, not a custom HTTP client, for MVP | Superseded by 0018 | Superseded: `opencode` is now one of two transports (`scripts/lib/transport.sh`) |
| [0003](0003-claude-code-only-scope.md) | Claude Code only scope for MVP | Accepted | Yes (`.claude-plugin/`, `hooks/hooks.json` remain Claude-Code-specific; no other host adapter exists) |
| [0004](0004-bash-jq-implementation.md) | Bash + jq implementation | Superseded by [0022](0022-python-core-port.md) | No (the core is Python, `hooks/` and `scripts/` are thin launchers) |
| [0005](0005-no-custom-mode-registry.md) | No custom mode registry, use OpenCode agents directly | Accepted | Yes (no registry code; agents addressed by name) |
| [0006](0006-mvp-scope-bulk-read-only.md) | MVP scope is bulk-read only | Partially superseded by 0015-0017 | Superseded: `code-write` now exists (`scripts/code-write`, `skills/code-writer/`) |
| [0007](0007-hard-pretooluse-gate-from-day-one.md) | Hard PreToolUse gate from day one | Accepted | Yes (`hooks/check-file-size`, `hooks/check-bash-read`) |
| [0008](0008-native-file-attachment-over-manual-wrapping.md) | Native `-f/--file` attachment over manual XML wrapping | Accepted | Yes (`scripts/lib/opencode.sh` uses `-f`, no XML wrapping) |
| [0009](0009-multi-host-scope-shift.md) | Scope shift from Claude Code only to Claude Code first, other hosts planned | Accepted | Partial: naming/framing done (repo, docs, cache paths); the adapter layer for an actual second host is explicitly not built yet, per its own Consequences |
| [0010](0010-defer-host-adapter-module-extraction.md) | Defer host-adapter module extraction until a second host is built | Accepted | Yes (decision is to do nothing structurally yet) |
| [0011](0011-model-registry-materialized-agents.md) | Multi-model registry with materialized agent files, not dynamic generation | Accepted | Yes (`scripts/shunt-models`, `scripts/lib/models.sh`) |
| [0012](0012-circuit-breaker-separate-from-model-selection.md) | Circuit breaker on consecutive failures only, no latency racing | Accepted | Yes (`scripts/py/shunt/breaker.py`, `scripts/py/shunt/breaker_config_cli.py`) |
| [0013](0013-thinking-off-by-default-per-model-opt-in.md) | Delegate model "thinking" mode off by default, per-model opt-in | Accepted | Yes (`scripts/shunt-models thinking`) |
| [0014](0014-enabled-flag-and-empty-registry-means-no-redirect.md) | Per-model enabled flag, and an empty registry means no read redirection | Accepted | Yes (`scripts/shunt-models enable/disable`, `hooks/check-file-size`) |
| [0015](0015-code-write-create-only-and-tag-protocol.md) | `code-write` is create-only, and the model returns text under a fixed tag protocol | Accepted | Yes (`scripts/code-write`, `scripts/lib/codewrite.sh`) |
| [0016](0016-code-write-roles-and-candidate-order.md) | `code-write` shares the model registry via per-model roles, not a second registry | Accepted | Yes (`scripts/lib/models.sh` role-aware candidates, `scripts/shunt-models roles`) |
| [0017](0017-code-write-boundaries-and-toctou.md) | `code-write` write boundaries, and the residual TOCTOU risk accepted for v1 | Accepted | Yes (`scripts/lib/codewrite.sh` path validation, denylist, atomic publish) |
| [0018](0018-direct-http-transport-alongside-opencode.md) | Direct HTTP transport alongside the OpenCode CLI, chosen per provider | Accepted | Yes (`scripts/lib/transport.sh`, `scripts/lib/transport-http.sh`, `scripts/lib/providers.sh`) |
| [0019](0019-api-key-storage.md) | API key storage: keyring, env var, plaintext or none, never in argv | Accepted | Yes (`scripts/lib/providers.sh`, `scripts/shunt-models key`) |
| [0020](0020-context-window-and-oversize-handling.md) | Context window from detection or the user, and `map_reduce` or `fail` for oversize input | Accepted | Yes (`scripts/py/shunt/context_detect.py`, `scripts/lib/transport-http.sh`) |
| [0021](0021-thinking-options-apply-to-both-transports.md) | Thinking options apply to both transports | Accepted | Yes (`scripts/lib/transport-http.sh` request body merge) |
| [0022](0022-python-core-port.md) | Port the core from bash and jq to Python | Accepted | Yes (`scripts/py/shunt/`, bridge `scripts/lib/py.sh`). Supersedes ADR 0004 |
