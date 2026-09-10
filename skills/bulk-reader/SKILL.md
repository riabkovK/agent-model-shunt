---
name: bulk-reader
description: Delegate reading large files to a custom model instead of loading them into Claude's own context. Use when the check-file-size or check-bash-read hooks block a Read/cat/head/tail on a file above the line threshold, or proactively when you need a summary/answer about a large file rather than its exact bytes.
---

# Bulk Reader

Delegates large-file reads to a custom user-configured model (via OpenCode),
so Claude's own context is not spent on file content that a cheaper model
can summarize or answer questions about just as well.

## When to use this skill

- A `Read` or `Bash cat/head/tail/less/more` call was blocked by this
  plugin's PreToolUse hooks because the target file exceeds
  `SHUNT_MIN_LINES` (default 350 lines).
- You need to understand, summarize, or answer a question about a large
  file's content, and do not need to reproduce its exact bytes.
- You are exploring an unfamiliar large file (config, generated code, log,
  vendored dependency, large data file) to answer a specific question.

## When NOT to use this skill

Do not delegate when:

- **You are about to edit the file.** Editing requires exact content and
  line numbers; re-read the specific section with `Read`'s `offset`/`limit`
  instead. The blocking hooks already allow `offset`/`limit` reads through.
- **You are debugging.** Root-causing a bug requires Claude's own reasoning
  over the exact code, not a paraphrase from another model.
- **The file is small.** Under the `SHUNT_MIN_LINES` threshold, just `Read`
  it directly; delegating adds latency for no savings.
- **The task is an architectural decision.** Delegated models are meant for
  cheap, mechanical extraction, not judgment calls about design.
- **You need verbatim output**, such as exact strings for a diff, credential
  values, or precise formatting. A delegated model may paraphrase.

## How to use it

Run `scripts/bulk-read` with a specific, narrow question and the file
path(s):

```bash
scripts/bulk-read --question "Which functions in this file call the database directly?" --paths path/to/large_file.py
```

Guidelines for the `--question`:

- Ask one specific, answerable question, not "summarize this file."
- If you need several distinct facts, prefer several narrow calls over one
  broad one; each is cheaper to get right and cheaper to verify.
- State the expected output shape when it matters (e.g. "list function names
  only, one per line").

The script prints the delegated model's answer to stdout, and a token/cost
usage line to stderr. Treat the answer as informative but unverified: for
anything load-bearing (a fact you will act on irreversibly), spot-check it
against the file yourself with a targeted `offset`/`limit` read.

## Configuration

See the project README for the `bulk-reader` OpenCode agent setup and the
`SHUNT_*` environment variables (`SHUNT_MIN_LINES`, `SHUNT_TIMEOUT_SECONDS`,
`SHUNT_OPENCODE_BIN`, `SHUNT_BULK_READER_AGENT`).
