# Architecture Decision Records

This directory records the key decisions made while designing
`cc-model-shunt`, an analog of `spotify/portal-ai-plugins`' `shunt` plugin
that routes delegated work to user-owned custom models via OpenCode instead
of Spotify's Portal CLI and AiKA models.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-openconnect-means-opencode.md) | "openconnect" means OpenCode | Accepted |
| [0002](0002-wrap-opencode-cli-not-http-client.md) | Wrap the OpenCode CLI, not a custom HTTP client, for MVP | Accepted |
| [0003](0003-claude-code-only-scope.md) | Claude Code only scope for MVP | Accepted |
| [0004](0004-bash-jq-implementation.md) | Bash + jq implementation | Accepted |
| [0005](0005-no-custom-mode-registry.md) | No custom mode registry, use OpenCode agents directly | Accepted |
| [0006](0006-mvp-scope-bulk-read-only.md) | MVP scope is bulk-read only | Accepted |
| [0007](0007-hard-pretooluse-gate-from-day-one.md) | Hard PreToolUse gate from day one | Accepted |
| [0008](0008-native-file-attachment-over-manual-wrapping.md) | Native `-f/--file` attachment over manual XML wrapping | Accepted |
