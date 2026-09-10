# 0007: Hard PreToolUse gate from day one

## Status

Accepted

## Context

The gate that redirects large-file reads to the bulk-reader skill can be
either a hard block (the `Read`/`Bash` call is refused outright, with a
message pointing at the skill) or a soft nudge (allow the call, but suggest
the skill via a warning). A soft nudge is easy to ignore, which would mean
the token-savings goal is only ever a suggestion.

## Decision

Use a hard `PreToolUse` block from day one, exactly as shunt does: `Read`
calls on files over `SHUNT_MIN_LINES` (default 350) without an
`offset`/`limit`, and `Bash` calls to `cat`/`head`/`tail`/`less`/`more` on
such files without a pipe or redirect, are both refused with a `block`
decision and a message pointing at the `/bulk-reader` skill.

## Consequences

- Guarantees the token savings actually happen, since the large read simply
  cannot proceed without delegating.
- Requires the escape hatches (`offset`/`limit` for `Read`, `|`/`>` for
  `Bash`) to stay correct, since these are the only way to read large-file
  content directly (e.g. for editing) without going through delegation.
- `ECC_GATEGUARD`-style env var opt-outs are not built in for this gate; if
  the threshold needs tuning, `SHUNT_MIN_LINES` is the documented lever.
