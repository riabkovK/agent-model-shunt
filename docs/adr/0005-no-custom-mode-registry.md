# 0005: No custom mode registry, use OpenCode agents directly

## Status

Accepted

## Context

shunt has its own "mode" concept (`aika modes`: bulk-reader, code-writer)
resolved by name through the Portal CLI's registry, because Portal CLI
itself has no first-class notion of a named, reusable agent configuration.
OpenCode already has this: `opencode agent create`, agent markdown files
with YAML frontmatter (`model`, `mode`, `description`, `tools`), addressed
by name via `opencode run --agent <name>`.

## Decision

Do not build a project-specific mode registry. Address OpenCode agents
directly by name (e.g. `bulk-reader`), configured as OpenCode agent files
under `~/.config/opencode/agents/`.

## Consequences

- Less code: no name-to-config resolution layer to build or maintain.
- Agent configuration (which model, what system prompt) lives in the
  user's own OpenCode config, not duplicated in this plugin.
- Setting up a new delegated task type means creating a new OpenCode agent
  (a manual, documented step), not writing new registry code.
