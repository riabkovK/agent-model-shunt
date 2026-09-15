# cc-model-shunt

A Claude Code plugin that shunts token-heavy, low-intelligence work (large
file reads) away from Claude and onto your own custom models, routed
through [OpenCode](https://opencode.ai).

It is an analog of Spotify's
[`portal-ai-plugins`](https://github.com/spotify/portal-ai-plugins) `shunt`
plugin, but delegates to models you configure yourself instead of Spotify's
Portal CLI / AiKA models. See [`docs/adr/`](docs/adr/README.md) for the
design decisions behind this project.

## Why

Reading a large file into Claude's context to answer one narrow question
("which functions call the database?", "what does this config value mean?")
spends a lot of Claude's own token budget on work a much cheaper model can
do just as well. This plugin blocks that pattern and redirects it to a
custom model of your choosing.

## How it works

1. `hooks/hooks.json` registers two `PreToolUse` hooks:
   - `hooks/check-file-size` blocks `Read` on files over `SHUNT_MIN_LINES`
     (default 350) lines, unless an `offset`/`limit` is given.
   - `hooks/check-bash-read` blocks `Bash` calls to
     `cat`/`head`/`tail`/`less`/`more` on such files, unless piped or
     redirected.
2. Both hooks point Claude at the `/bulk-reader` skill
   (`skills/bulk-reader/SKILL.md`) instead of letting the read through.
3. That skill runs `scripts/bulk-read --question "..." --paths file...`,
   which shells out to `opencode run --agent bulk-reader -f file... "question"
   --format json` and prints the delegated model's answer.

## Prerequisites

- `bash`, `jq`, GNU `coreutils` (`timeout`).
- [OpenCode](https://opencode.ai) installed and on `PATH`, with at least one
  custom provider configured in `~/.config/opencode/opencode.json`. See
  OpenCode's docs for adding an OpenAI-compatible provider.

## Setup

### 1. Install the plugin

This repo ships its own local marketplace (`.claude-plugin/marketplace.json`,
one entry pointing back at `.claude-plugin/plugin.json`), so a clone can be
installed straight from its path, no published marketplace required yet:

```bash
claude plugin marketplace add /path/to/this/repo
claude plugin install cc-model-shunt@cc-model-shunt-marketplace
```

(`/plugin marketplace add` / `/plugin install` are the equivalent slash
commands if you're doing this interactively rather than from a script.)
Restart the session for the newly installed hooks to take effect. A
published marketplace for a one-command install from a fresh clone is
tracked in `docs/TODO.md`.

### 2. Create the `bulk-reader` OpenCode agent

This plugin does not create global OpenCode configuration on your machine
automatically; you create the agent once yourself. Create
`~/.config/opencode/agents/bulk-reader.md`:

```markdown
---
description: Precise, read-only code analyst for delegated bulk-read questions.
mode: primary
model: your-provider/your-model
tools:
  read: true
  bash: false
  write: false
  edit: false
  glob: false
  grep: false
  task: false
  webfetch: false
  todowrite: false
  skill: false
  changed-files: false
  dependency-analyzer: false
---

You are a precise code analyst. Answer the question about the attached
file(s) directly and concisely. Use bullet points, not prose. Do not
speculate beyond what is in the attached content. Do not suggest edits or
next steps unless asked.
```

Replace `your-provider/your-model` with a model from your own
`opencode.json` provider config (for example
`bootsman/Spark/deepseek-ai/DeepSeek-V4-Flash-0731`).

`mode: primary` is required: `opencode run --agent <name>` only invokes
primary agents directly; a `subagent`-mode agent is silently ignored and
`opencode` falls back to the CLI's own default agent instead (which loads
your entire normal working setup, defeating the point of delegating). The
explicit `tools: false` entries turn off every OpenCode built-in tool this
agent doesn't need for a read-only bulk-read task.

Every non-`read` tool listed above is on by default unless turned off
explicitly, and `scripts/lib/opencode.sh` isolates each delegated call into
its own minimal `XDG_CONFIG_HOME` (see [Configuration](#configuration))
containing only this agent and the one provider its `model:` references, so
your regular OpenCode skills/commands/MCP servers never get attached to a
delegated call. Without that isolation, `opencode run` otherwise loads your
*entire* global `~/.config/opencode` config for every call; on a setup with
several MCP servers configured this was observed inflating a single
small-file read from a few thousand prompt tokens to 70,000+, which you'd
be paying for on the delegated model regardless of Claude's own savings.
This isolation is automatic; no extra setup step is required.

### 3. Verify

```bash
opencode agent list   # confirm "bulk-reader" is listed
scripts/bulk-read --question "What license is this project under?" --paths LICENSE
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SHUNT_MIN_LINES` | `350` | Line-count threshold above which reads are blocked and delegated. |
| `SHUNT_OPENCODE_BIN` | `opencode` | Path or name of the OpenCode binary to invoke. |
| `SHUNT_TIMEOUT_SECONDS` | `300` | Timeout for a single delegated `opencode run` call. |
| `SHUNT_BULK_READER_AGENT` | `bulk-reader` | Name of the OpenCode agent used for bulk-read delegation. |
| `SHUNT_HOOKS_DISABLED` | unset | When `1`/`true`/`yes`, both PreToolUse hooks allow every read through unchecked. See the `/toggle-hooks` skill for A/B testing hooks-on vs hooks-off. |
| `SHUNT_OPENCODE_CONFIG_HOME` | `~/.config/opencode` | Where to read your real OpenCode agent/provider config from, when building the isolated per-call config below. |
| `SHUNT_ISOLATED_CONFIG_DIR` | `~/.cache/cc-model-shunt/opencode-config` | Where the isolated, minimal OpenCode config (one agent, one provider) is written and reused for every delegated call. Safe to delete; it's regenerated on each `opencode run`. |

## Evals

```bash
evals/run.sh                # hook routing decisions — no network needed
evals/transport-evals.sh    # one live scripts/bulk-read call — needs OpenCode + a provider
evals/benchmark.sh          # token-savings + latency of the delegated OpenCode call, in isolation
evals/baseline-benchmark.sh # shunt vs Claude reading the files directly — needs OpenCode + a provider + `claude` CLI
```

`evals/benchmark.sh` measures, per scenario in `evals/benchmarks.json`:

- **Token savings**: a `chars/4` estimate (the same conservative heuristic
  shunt uses) of the raw file content Claude would otherwise read, versus
  the delegated model's answer that lands in Claude's context instead.
- **Latency**: wall-clock time for the delegated `opencode run` round trip.
  Delegation trades Claude context tokens for this added latency; the
  script reports both so you can judge the trade-off for your own workflow
  rather than assuming delegation is free.
- **Custom-model usage**: the real input/output token counts OpenCode
  reports for the delegated call, shown for transparency. This is a
  separate cost paid by the custom model, not folded into the savings %.

The three scenarios (`single-large-file`, `source-plus-test`,
`multi-file-cross-read`) mirror the case shapes from shunt's own
benchmarks, run against real production Go source under
`evals/fixtures/echo/` (`echo.go`; `cors.go` + `cors_test.go`;
`context.go` + `router.go` + `group.go`), pinned copies of
[labstack/echo](https://github.com/labstack/echo) `v5.3.1` (MIT license,
kept alongside in that directory; see
[`evals/fixtures/echo/NOTICE.md`](evals/fixtures/echo/NOTICE.md) for
provenance and how to re-fetch them). Real, unmodified library code makes
these scenarios representative of what you'd actually ask a coding agent
to read, rather than synthetic filler.

`evals/baseline-benchmark.sh` runs the same scenarios a second way, to
answer the actual "is this worth it" question: for each scenario, in each
iteration, it sends the question plus the raw file content to a real
`claude -p --output-format json` call twice — once as a brand-new session
(`no-resume`) and once chained into the same session as the prior scenario
(`resume`, so the one-time cost of priming this project's system prompt is
only paid once, matching how a real interactive session amortizes it) —
then runs the same scenario through `scripts/bulk-read` (`shunt`) and
writes all three as JSON rows to `evals/results/baseline-benchmark.jsonl`.
`evals/aggregate-baseline-results.py` (run automatically at the end) turns
those rows into `evals/results/baseline-benchmark-summary.json` and a
printed comparison table: real wall-clock time and real token/cost usage
for all three variants, not estimates. This script spends real money on
your Claude account (it prints the total cost at the end) and its
`ITERATIONS` calls have no built-in retry, so pick a count you're willing
to pay for and run it deliberately, not in a loop.

For `no-resume`/`resume`, `context_tokens` is the real
`input + cache_read + cache_creation` usage the `claude -p` call reports:
what Claude actually paid to have the raw file content in context. For
`shunt`, `context_tokens` is a chars/4 estimate of only the delegate's
answer text (the thing that would land in Claude's context if a live
session relayed it) — it does not include the tokens a real session would
spend emitting the `Bash` call to `scripts/bulk-read` or reading the
`/bulk-reader` skill instructions that route it there, so it's a
best-case, not a full accounting of shunt's Claude-side cost. The
delegate model's own input/output tokens are tracked separately
(`delegate_input_tokens`/`delegate_output_tokens`) and are not folded into
this comparison at all.

`context_tokens` for `no-resume`/`resume` is dominated by this project's
own Claude Code system prompt and tool/skill/hook definitions, not by the
fixture file: a 25-40KB Go file is only ~6,000-10,000 tokens by the
chars/4 estimate, tens of thousands of tokens short of the totals this
script reports. Every `no-resume` call is a genuinely fresh `claude -p`
process, so it pays that bootstrap cost in full, every time - that's real
if your workflow spins up a fresh headless call per question, but it's not
representative of one already-open interactive session reading several
files, where the bootstrap is paid once and then served from prompt cache.
`resume` approximates that real session better, but `context_tokens` still
sums cached and fresh tokens together at equal weight, so it doesn't fall
much even though the *dollar* cost does (`cost_usd` in each row and in
`baseline-benchmark-summary.json` prices cache reads far below fresh
tokens). Read `cost_usd`, not `context_tokens`, if you want the closest
proxy to "what would this actually cost me in a live session."

**[`docs/shunt-ledger.html`](docs/shunt-ledger.html)** is the full write-up
of the latest `evals/baseline-benchmark.sh` run: per-scenario token, cost,
and time comparisons for `no-resume` / `resume` / `shunt`. It's a static
file checked into this repo; open it directly in a browser (GitHub's own
file viewer renders `.html` as source, not as a page, so save/clone the
repo to view it rendered).

> The fixtures moved to real `labstack/echo` source (see above); the
> ledger and the results file it's built from need a fresh
> `evals/baseline-benchmark.sh` run against them before the numbers are
> trustworthy again — that run spends real money on your Claude account,
> so it isn't run automatically as part of an edit.

| Variable | Default | Purpose |
|---|---|---|
| `SHUNT_BASELINE_MODEL` | `sonnet` | Model alias passed to `claude -p --model` for the baseline side of `evals/baseline-benchmark.sh`. |
| `SHUNT_BASELINE_TIMEOUT` | `120` | Timeout (seconds) for each baseline `claude -p` call. |
| `ITERATIONS` | `3` | Repeats per scenario/variant in `evals/baseline-benchmark.sh`. Total `claude -p` calls = `ITERATIONS * 3 scenarios * 2` (no-resume + resume). |

## Scope

MVP scope is `bulk-read` only (large-file reads). `code-write` (delegated
boilerplate generation, as in shunt) is a planned future phase, not
implemented here. See [ADR 0006](docs/adr/0006-mvp-scope-bulk-read-only.md).

This plugin wraps the `opencode` CLI as a subprocess for MVP; a direct HTTP
client against your provider is a planned future phase. See
[ADR 0002](docs/adr/0002-wrap-opencode-cli-not-http-client.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
