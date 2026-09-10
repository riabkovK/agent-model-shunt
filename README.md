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

Install this repository as a Claude Code plugin (see Claude Code's plugin
installation docs for your preferred method: local path, git URL, or a
marketplace).

### 2. Create the `bulk-reader` OpenCode agent

This plugin does not create global OpenCode configuration on your machine
automatically; you create the agent once yourself. Create
`~/.config/opencode/agents/bulk-reader.md`:

```markdown
---
description: Precise, read-only code analyst for delegated bulk-read questions.
mode: subagent
model: your-provider/your-model
---

You are a precise code analyst. Answer the question about the attached
file(s) directly and concisely. Use bullet points, not prose. Do not
speculate beyond what is in the attached content. Do not suggest edits or
next steps unless asked.
```

Replace `your-provider/your-model` with a model from your own
`opencode.json` provider config (for example `bootsman/qwen3.8`).

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
| `SHUNT_TIMEOUT_SECONDS` | `120` | Timeout for a single delegated `opencode run` call. |
| `SHUNT_BULK_READER_AGENT` | `bulk-reader` | Name of the OpenCode agent used for bulk-read delegation. |

## Evals

```bash
evals/run.sh              # hook routing decisions — no network needed
evals/transport-evals.sh  # one live scripts/bulk-read call — needs OpenCode + a provider
evals/benchmark.sh        # token-savings + latency benchmark — needs OpenCode + a provider
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
benchmarks, run against synthetic fixture files under `evals/fixtures/`
(`api-client.ts`, `task-queue.ts` + `task-queue.test.ts`, `event-bus.ts`;
regenerate with `evals/fixtures/generate.sh` if you change the word lists
in that script). Fixture content is original, not copied from shunt.

## Scope

MVP scope is `bulk-read` only (large-file reads). `code-write` (delegated
boilerplate generation, as in shunt) is a planned future phase, not
implemented here. See [ADR 0006](docs/adr/0006-mvp-scope-bulk-read-only.md).

This plugin wraps the `opencode` CLI as a subprocess for MVP; a direct HTTP
client against your provider is a planned future phase. See
[ADR 0002](docs/adr/0002-wrap-opencode-cli-not-http-client.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
