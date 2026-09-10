# 0003: Claude Code only scope for MVP

## Status

Accepted

## Context

Spotify's `portal-ai-plugins` targets multiple hosts (Claude Code, and
potentially other coding CLIs). Supporting multiple hosts multiplies the
surface area (different hook systems, different plugin formats) for a
project that is still validating whether the delegation concept works at
all.

## Decision

Scope this project to Claude Code only. No Codex, Cursor, or other host
support in MVP.

## Consequences

- The plugin format (`.claude-plugin/plugin.json`, `hooks/hooks.json`) is
  Claude-Code-specific by design; porting to another host later would
  require a separate adapter layer.
- Keeps the MVP small and testable in the one environment the user
  actually works in day to day.
