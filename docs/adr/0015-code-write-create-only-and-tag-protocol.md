# 0015: `code-write` is create-only, and the model returns text under a fixed tag protocol

## Status

Accepted

## Context

`code-write` ([ADR 0006](0006-mvp-scope-bulk-read-only.md)'s deferred second
scenario) delegates generating a brand-new file to a custom model. Two
questions had to be settled before anything else: who is allowed to touch
disk, and what an existing file means to this script.

The reference implementation studied
(`spotify/portal-ai-plugins`'s `shunt/scripts/code-write`) makes a tool-less
chat call and does `echo "$clean" > "$target"` after stripping markdown
fences, with no overwrite guard, no response protocol beyond fence
stripping, and no validation. That is enough to prove the token-savings idea
but not enough to trust with real edits.

## Decision

**The script writes to disk, never the model.** The delegate agent has every
OpenCode tool disabled, including `read`; input files reach it only as
native `-f` attachments ([ADR 0008](0008-native-file-attachment-over-manual-wrapping.md)).
The model returns text, `scripts/lib/codewrite.sh` validates it, and only the
script calls `write`. Two alternatives were rejected: having Claude re-emit
the delegate's code itself (spends the exact output tokens `code-write`
exists to save) and letting the model write via its own tools (permission
scoping and agentic-loop risk on a v1 feature that touches the working
tree).

**Create-only.** `--target` must not exist yet — as a file, a directory, or a
symlink. Any of those is a hard refusal before the model is ever called.
Editing an existing file is explicitly out of scope for `code-write`; Claude
uses `Edit`/`Write` directly for that, which asks for permission the way
`code-write` deliberately does not.

**Fixed reply protocol**, checked only in the model's response stream, never
looked for in the file that ends up on disk:

```
<SHUNT-NOTES>
skipped items, missing symbols, doubts
</SHUNT-NOTES>
<SHUNT-CODE>
file content
</SHUNT-CODE>
```

Both tags must appear exactly once, in that order, as exact whole-line
matches, with only blank lines allowed before the first tag, between the two
sections, and after the closing `</SHUNT-CODE>`. A response cut off by a
length limit therefore lacks its closing tag and parses as unusable rather
than as a truncated file silently written to disk. A duplicate, missing, or
out-of-order tag, or any text outside the two sections, is refused and
nothing is written. Only an outer markdown fence wrapped around the whole
`SHUNT-CODE` body is stripped; fence lines inside the content are left alone,
since a generated Markdown file is allowed to start and end with its own
fenced block. Empty `SHUNT-CODE` with notes is a deliberate refusal by the
model (exit 3, notes surfaced to Claude); empty `SHUNT-CODE` without notes is
an error.

## Consequences

- A truncated, malformed, or off-protocol reply is caught by exact string
  matching against the transcript, before any file write is attempted; no
  partial or corrupted file can land on disk from a bad response.
- The denylist and path-safety checks in
  [ADR 0017](0017-code-write-boundaries-and-toctou.md) run before the model
  call, on the same "refuse first, call second" principle this ADR
  establishes for create-only.
- `--kind test` additionally requires `--source` (the code under test); see
  `skills/code-writer/SKILL.md` and the built-in test rules in
  `prompts/test-rules.md` for the behavior this protocol is meant to
  produce, not just how it is packaged.
- Multi-file output per call is not supported: exactly one `--target` per
  invocation, several calls (feeding one call's output back in as a later
  call's `--reference`) if more than one file is needed. Revisiting this is
  a new decision, not an extension of this ADR.
</content>
