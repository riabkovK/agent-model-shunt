# agent-model-shunt

Shunts token-heavy, low-intelligence work (large file reads) away from
your coding agent and onto your own custom models, routed through
a direct OpenAI-compatible HTTP call or the [OpenCode](https://opencode.ai)
CLI, chosen per provider. Currently implemented for Claude Code
(see [`.claude-plugin/`](.claude-plugin/)); built to extend to other agent
hosts (Codex, etc.) as they're added.

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
   which sends the files and question to the delegated model and prints its
   answer. Each provider uses one of two transports:
   - `http` (recommended, faster): one POST (Python `http.client`, no
     `curl`) to the provider's OpenAI-compatible `/chat/completions` endpoint.
   - `opencode` (the previous path, still supported): shells out to
     `opencode run --agent bulk-reader -f file... "question" --format json`.

   A provider with no `transport` set uses `opencode`, so existing setups keep
   working.

The core is Python 3.11+ using only the standard library (package
`scripts/py/shunt/`, entry point `scripts/py/shunt_main.py`). Each bulk-read,
each code-write and each hook runs in one Python process. The files under
`scripts/` and `hooks/` are thin bash launchers (a few bash helpers in
`scripts/lib/` remain for the registry, provider and breaker config commands).

## Prerequisites

- `bash` and `python3` 3.11 or newer (standard library only, nothing to
  `pip install`). No `jq`, `curl` or GNU `coreutils` are needed at run time.
- [OpenCode](https://opencode.ai) installed and on `PATH`, only for providers
  on the `opencode` transport. Those need a custom provider configured in
  `~/.config/opencode/opencode.json`.
- Optional: a keyring backend (`secret-tool`, `security` or `kwallet-query`)
  to store `http` provider keys.

## Setup

To use the `http` transport, follow
[Add an HTTP model](#add-an-http-model-recommended) below. Steps 2 and 3 of
the install flow below create the OpenCode agent and apply only to the
`opencode` transport.

### 1. Install the plugin

This repo ships its own marketplace (`.claude-plugin/marketplace.json`, one
entry pointing back at `.claude-plugin/plugin.json`). Install directly from
GitHub, no local clone required:

```bash
claude plugin marketplace add riabkovK/agent-model-shunt
claude plugin install agent-model-shunt@agent-model-shunt-marketplace
```

Or, working from a local clone:

```bash
claude plugin marketplace add /path/to/this/repo
claude plugin install agent-model-shunt@agent-model-shunt-marketplace
```

(`/plugin marketplace add` / `/plugin install` are the equivalent slash
commands if you're doing this interactively rather than from a script.)
Restart the session for the newly installed hooks to take effect.

**Updating:** third-party marketplaces don't auto-update by default. Run
`claude plugin marketplace update agent-model-shunt-marketplace` (or
`/plugin marketplace update agent-model-shunt-marketplace`) to pick up new
commits, or toggle auto-update on for this marketplace under `/plugin` →
Marketplaces.

**Disabling vs. uninstalling:** `claude plugin disable
agent-model-shunt@agent-model-shunt-marketplace` turns the plugin off while
keeping its config, `claude plugin enable ...` turns it back on. `claude
plugin uninstall agent-model-shunt@agent-model-shunt-marketplace` removes it
entirely. Slash-command equivalents (`/plugin disable`, `/plugin enable`,
`/plugin uninstall`) work the same way.

### Add an HTTP model (recommended)

In this order (the `/model-config` skill walks through it):

1. Provider: `scripts/shunt-models provider set <name> --transport http
   --base-url <url> --key <keyring|plaintext|none|env:VARNAME>`.
2. Key: run `! <plugin-root>/scripts/shunt-models key set <name>` yourself
   (hidden prompt). Never paste a key into chat. Check with `key status
   <name>`.
3. `scripts/shunt-models add <provider/model>`.
4. `scripts/shunt-models detect-context <provider/model> --write`. If
   detection fails, store the window with `set-context`.

Already on OpenCode providers? `scripts/shunt-models --migrate-from-opencode`
is a dry run that prints the plan. `--migrate-from-opencode --apply` writes it
and backs up `models.json` and `providers.json` first. It asks y/N in a
terminal. Without a terminal (for example when Claude runs it) it refuses
unless `--yes` is passed. See
[Key storage](#key-storage-http-transport) for where keys go.

### 2. Create the `bulk-reader` OpenCode agent (opencode transport)

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
`your-provider/Spark/deepseek-ai/DeepSeek-V4-Flash-0731`).

`mode: primary` is required: `opencode run --agent <name>` only invokes
primary agents directly; a `subagent`-mode agent is silently ignored and
`opencode` falls back to the CLI's own default agent instead (which loads
your entire normal working setup, defeating the point of delegating). The
explicit `tools: false` entries turn off every OpenCode built-in tool this
agent doesn't need for a read-only bulk-read task.

Every non-`read` tool listed above is on by default unless turned off
explicitly, and the Python core (`scripts/py/shunt/opencode_cli.py`) isolates each delegated call into
its own minimal `XDG_CONFIG_HOME` (see [Configuration](#configuration))
containing only this agent and the one provider its `model:` references, so
your regular OpenCode skills/commands/MCP servers never get attached to a
delegated call. Without that isolation, `opencode run` otherwise loads your
*entire* global `~/.config/opencode` config for every call; on a setup with
several MCP servers configured this was observed inflating a single
small-file read from a few thousand prompt tokens to 70,000+, which you'd
be paying for on the delegated model regardless of Claude's own savings.
This isolation is automatic; no extra setup step is required.

### 3. Verify (opencode transport)

```bash
opencode agent list   # confirm "bulk-reader" is listed
scripts/bulk-read --question "What license is this project under?" --paths LICENSE
```

## Multiple delegate models + automatic failover

Step 2 above sets up a single hand-written agent (`SHUNT_BULK_READER_AGENT`,
default `bulk-reader`). That's still all you need to get started, but you
can instead register several delegate models and let shunt rotate across
them automatically. Drive this through the `/model-config` skill, never by
hand-editing the files below:

- **Registry** (`~/.config/agent-model-shunt/models.json`, written by
  `scripts/shunt-models`): a priority-ordered list of `provider/model`
  entries. `scripts/shunt-models add <provider/model>` materializes a
  `bulk-reader.md`-shaped agent file for it under
  `~/.config/agent-model-shunt/agents/` automatically. You never
  hand-write these once a registry exists.
- **Failover**: on each delegated call, shunt tries the registry's active
  model first, then the rest in priority order, skipping any model whose
  circuit breaker is currently open. If a registry exists but every
  candidate is paused, the file-size hook allows the direct `Read` through
  instead of denying it, so Claude isn't stranded with no usable path.
- **Disable / remove**: `scripts/shunt-models disable <provider/model>`
  takes a model out of rotation without deleting it (`enable` brings it
  back in place). `remove` deletes it along with its agent file and
  failover state. With no models left, or none enabled, the hook stops
  redirecting large reads and Claude reads files directly.
- **Circuit breaker**: N consecutive failures (errors/timeouts, not
  latency) on a model pause it for a cooldown period before it's retried.
  Configurable via `scripts/shunt-breaker-config` (defaults: 3 failures /
  300s cooldown). The `/model-config` skill shows these settings and
  changes them.
- **Thinking/extended-reasoning**: off by default for every registered
  model. Turn it on per model, with the provider's own reasoning options,
  via `scripts/shunt-models thinking <provider/model> on '<options-json>'`
  (see the `/model-config` skill). It applies to both transports
  ([ADR 0021](docs/adr/0021-thinking-options-apply-to-both-transports.md)).

If no registry file exists, shunt stays in the legacy single-agent mode
described in [Setup](#setup) above. See [Management skills](#management-skills)
for `/model-config` and the other skills that manage shunt itself.

### Key storage (HTTP transport)

Each provider's `key.type` in `providers.json` is one of:

| Type | Where the key lives | Trade-off |
|---|---|---|
| `keyring` | OS keyring (`secret-tool`, `security` or `kwallet-query`) | Strongest, but needs a backend. None is usable under WSL. |
| `env` | An environment variable you export (`env:VARNAME`) | Nothing stored by the plugin. The variable must be set where Claude Code runs. |
| `plaintext` | `providers.json`, mode 600 | Weakest. Setting it prints a warning. |
| `none` | No key | For local endpoints without auth. |

Keys never go in argv, logs or chat. Enter one with the `!` prefix, which
reads it from a hidden prompt:
`! <plugin-root>/scripts/shunt-models key set <provider>`. On macOS the
`security` tool briefly shows the key in its own argv during `key set`, so an
`env` key avoids that. See
[ADR 0019](docs/adr/0019-api-key-storage.md).

### Healthcheck for local servers (HTTP transport)

A server on a laptop (LM Studio, ollama, llama.cpp) may accept the TCP
connection while the machine sleeps and still never answer. Set
`"healthcheck": true` on such a provider in `providers.json`. Providers created
with `provider set` or by the OpenCode migration get it on by default. A
provider whose entry has no `healthcheck` field counts as off. Turn it on or
off later with:

```bash
scripts/shunt-models provider set lmstudio --healthcheck off   # or: on
```

The entry then looks like this:

```json
{"version": 1, "providers": {
  "lmstudio": {"transport": "http", "base_url": "http://192.168.1.20:1234/v1",
               "key": {"type": "none"}, "healthcheck": true}}}
```

The check never slows a request down. A request only reads a small status cache
(`~/.cache/agent-model-shunt/healthcheck.json`, per provider, base_url and
model, `healthy` or `unhealthy` with the time of the check, no key in it) and
goes on at once:

- Unhealthy for less than `SHUNT_HEALTHCHECK_RETRY` seconds (default 30): the
  call stops with `shunt: <model> healthcheck failed: ...`, counts as
  "unreachable" and the next model is tried, with no delay.
- Healthy, unknown, or older than its limit (`SHUNT_HEALTHCHECK_TTL` seconds,
  default 600, for healthy; the retry time for unhealthy): the real call goes
  on at once. An unknown or stale status also starts one detached background
  probe (`shunt_main.py healthcheck-refresh <provider> <model>`, one child for all models at session start). An unhealthy
  status older than the retry time is therefore tried again by the real call
  itself, plus a probe. A model that was only reachable over a VPN is back at
  the first call after the retry time once the VPN is up.
- The probe reads the provider and its key itself, so a key is never in a
  command line. One probe per model runs at a time (a lock file in the cache
  dir), it has a time cap and its failures are silent. A good probe also
  clears the model's circuit breaker state.
- The real call keeps the status current: a success marks the model healthy, a
  failed connection, a 404 or a 5xx marks it unhealthy. Other errors (auth, other 4xx, oversize, a
  timeout on a long reply) leave it alone.
- The session start hook starts a probe for each enabled model of a healthcheck
  provider whose status is missing or stale. It does not wait for them.
- For a provider with the healthcheck on, "unreachable" failures (including a
  refused connection or an unknown host) are not counted by the circuit breaker:
  the unhealthy status, which expires after the retry time, takes its place.

The probe checks the model in two steps, both with the same
auth header. First `GET <base_url>/models`: a connection error, a timeout or a
5xx answer is unhealthy, and so is a readable model list that lacks the
configured model (`model not listed`). A 4xx (some servers have no `/models`) or
a list that cannot be read passes this step. Then a one token
`POST <base_url>/chat/completions` for the model (`max_tokens` 1, no stream).
Any 2xx is healthy, and so are 400 and 422 (the model route answered, for
instance a reasoning model that rejects `max_tokens`) and 401 or 403 (the real
call then reports the auth error). A 404, a 5xx, a timeout or no connection is
unhealthy. The probe's tokens are not written to the usage log. The completion
step may take `SHUNT_HEALTHCHECK_MODEL_TIMEOUT` seconds (default 30), because a
local server may have to load the model first.

### Large files (HTTP transport)

Each model has a `context_tokens` value, from `shunt-models detect-context
--write` or `shunt-models set-context`. It is never guessed, and without it
only small requests are sent. `oversize_policy` decides what happens to input
that does not fit: `map_reduce` (default) splits it into overlapping chunks and
merges the answers, `fail` makes this model refuse so the next model in the
failover order is tried. `code-write` always refuses oversize input. A refusal
for size is not the model's fault, so it never counts toward the circuit
breaker. When no model can take the input, bulk-read says so ("no delegate
model can take this input") and Claude reads the file itself. Models on the
`opencode` transport refuse a file over 2000 lines, 50 KB or a 2000-character
line, since `opencode run -f` would silently cut it. Set it with `shunt-models oversize-policy <provider/model>
<map_reduce|fail|--clear>`. A chunked call is bounded by the timeouts
`SHUNT_TIMEOUT_SECONDS` and `SHUNT_TOTAL_TIMEOUT_SECONDS` in the
[Configuration](#configuration) table. See
[ADR 0020](docs/adr/0020-context-window-and-oversize-handling.md).

## Performance

Measured 2026-10-09 on mac with model qwen36: `bulk-read` of a 316-line file,
3 runs each, averages.

| Transport | Thinking off | Thinking on |
|---|---|---|
| `opencode` | 40.8s | 91.7s |
| `http` | 15.4s | 77.8s |

HTTP is about 2.6x faster without thinking. With thinking on, generation time
dominates. Details in
[ADR 0018](docs/adr/0018-direct-http-transport-alongside-opencode.md).

## Code-writer: delegated generation of new files

Where `bulk-read` delegates a large *read*, `code-writer` delegates
generating a single brand-new file (a test, a config file, a stub, or
docstring-heavy boilerplate), so Claude doesn't spend its own output tokens
on predictable generation. Claude reviews the result afterwards, which
costs only input tokens. See `skills/code-writer/SKILL.md` for the full
"when to delegate" guidance, the call contract, the mandatory
post-generation review, and the self-fix loop.

```bash
scripts/code-write --kind test|generic --spec "<what to generate>" \
  --reference <file>... [--source <file>...] [--rules <file>...] \
  [--allow-outside] --target <new file>
```

- `--target` must not exist yet: `code-write` is create-only, never edits an
  existing file. See [ADR 0015](docs/adr/0015-code-write-create-only-and-tag-protocol.md).
- `--kind test` requires `--source` (the code under test); `--kind generic`
  makes it optional. Built-in, non-disableable test-writing rules
  (`prompts/test-rules.md`) are always injected for `--kind test`.
- The delegate model has every tool disabled, including `read`. It only
  ever returns text under a fixed tag protocol
  (`<SHUNT-NOTES>`/`<SHUNT-CODE>`), which the script validates before
  writing anything. Path validation and a denylist (`.git`, `.claude`,
  `.env*`, `CLAUDE.md`, build and test entry points such as `setup.py` and
  `package.json`, and more) run before the model is ever called; see
  [ADR 0017](docs/adr/0017-code-write-boundaries-and-toctou.md) for the full
  list and the accepted TOCTOU trade-off.
- A model needs the `code-write` role to be a candidate for this script.
  Add it with `scripts/shunt-models roles <provider/model> code-write` (or
  leave `roles` unset, which grants every role). It shares the same
  registry, priority order, and circuit breaker as `bulk-read`, tracked
  separately per role. See [ADR 0016](docs/adr/0016-code-write-roles-and-candidate-order.md).
- On a build/test failure after generation, the skill retries the delegate
  itself (appending the raw failure output to `--spec`) before falling back
  to Claude fixing the file by hand. The retry count is configurable
  (`scripts/shunt-codewrite-config`, default 1, global). Drive it through
  `/model-config`.

| Variable | Default | Purpose |
|---|---|---|
| `SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE` | `~/.config/agent-model-shunt/code-write-self-fix-config.json` | Self-fix retry-count override, written by `scripts/shunt-codewrite-config`. |
| `SHUNT_CODE_WRITE_SELF_FIX_RETRIES` | `1` | Env override for how many times the self-fix loop re-calls `code-write` on a build/test failure; takes precedence over the config file. `0` disables automatic retry. |

## Orchestrator rule

A `SessionStart` hook (`hooks/session-start-orchestrator`) injects a short
delegation rule into the session, so Claude knows when to use which shunt
skill without you repeating it. It runs on `startup`, `resume`, `clear` and
`compact`, so the rule is back after a resume, a clear or a compaction.

What the rule shows, per role (`bulk-read`, `code-write`):

- **Ready**: the role has an enabled model whose breaker is closed. The bullets
  from that skill's fragment are shown.
- **Unavailable**: no enabled model has the role. The rule says to handle the
  work directly.
- **Breaker open**: every candidate for the role is paused. The rule says to
  handle the work directly until the cooldown ends.
- **Hooks disabled**: with a registry present and `SHUNT_HOOKS_DISABLED` set to
  `1`, `true` or `yes` (see `/toggle-hooks`), one
  line notes that reads are not hook-gated and delegation is by judgment only.
- **No models**: if no registry exists, one line points at `/model-config`.

The rule never includes a model id or name, only fixed state words and the
fragment text. It is capped at 3000 characters (whole trailing lines are
dropped past that). The hook always exits 0 and prints nothing on any error,
so a broken registry or fragment can never block a session.

### Register a skill

Each delegating skill ships a fragment next to its `SKILL.md`. Built-in
fragments live at `skills/bulk-reader/orchestrator.md` and
`skills/code-writer/orchestrator.md`. A fragment looks like this:

```
role: code-write
- ONE new predictable file (tests, config, stubs): use /code-writer.
- Not for existing files or logic-heavy code. Skip below {{MIN_LINES}} lines.
```

Format:

- An optional first line `role: <role>` (lowercase letters, digits and
  hyphens, at most 32 characters). The role must exist in the model registry,
  otherwise the fragment is ignored. Without a role the bullets are always shown.
- 1 to 6 bullet lines, each starting with `- `. Blank lines are ignored.
  Anything else makes the fragment invalid.
- `{{MIN_LINES}}` is the only substitution (the `SHUNT_MIN_LINES` value,
  default 350). Nothing in a fragment is ever executed.
- Caps: 160 characters per line, 600 for the whole body, 4096 bytes per file.
  Control characters, ANSI sequences and invisible Unicode are stripped.

You can add or override fragments without touching the plugin. Put `*.md` files
in `$SHUNT_ORCHESTRATOR_DIR`, by default
`${XDG_CONFIG_HOME:-$HOME/.config}/agent-model-shunt/orchestrator.d`. The
directory is used only if it is an absolute path, owned by you, and not group or
world writable, and no ancestor up to `/` is group or world writable unless it
has the sticky bit (like `/tmp`). Only regular, non-symlink `.md` files owned by
you and not group or world writable are read (dotfiles are skipped), at most 16 valid fragments from at most 64 examined files.

A user file named `<skill-dir-name>.md` (for example `bulk-reader.md`) replaces
that built-in fragment. If the override is invalid, it is silently skipped and
the built-in stays. An override whose role the registry does not know drops
both, so the skill gets no fragment. Invalid fragments are always skipped without an error.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SHUNT_MIN_LINES` | `350` | Line-count threshold above which reads are blocked and delegated. |
| `SHUNT_OPENCODE_BIN` | `opencode` | Path or name of the OpenCode binary to invoke (`opencode` transport only). |
| `SHUNT_TIMEOUT_SECONDS` | `300` | Timeout for a single delegated `opencode run` call, and for each single HTTP request with the `http` transport. |
| `SHUNT_TOTAL_TIMEOUT_SECONDS` | 3 x `SHUNT_TIMEOUT_SECONDS` (`900`) | `http` transport only: deadline for one model attempt, covering every part and the merge request of a chunked (map_reduce) call. It applies per model: when a model fails over, the next candidate starts with a fresh deadline, so a failover chain can take up to this long once per candidate. It is checked before each request, and each request's timeout is capped at the time left. When it runs out, the attempt fails as a timeout (counted by the circuit breaker, the next model is tried) and stderr says how many parts finished. A single unchunked request is only affected when this is set below `SHUNT_TIMEOUT_SECONDS`. The default follows `SHUNT_TIMEOUT_SECONDS` rounded up to whole seconds, and is no total deadline when `SHUNT_TIMEOUT_SECONDS` is `0` (no limit). Must be a positive whole number of seconds. |
| `SHUNT_BULK_READER_AGENT` | `bulk-reader` | Name of the OpenCode agent used for bulk-read delegation when no models registry exists (legacy single-agent mode). |
| `SHUNT_HOOKS_DISABLED` | unset | When `1`/`true`/`yes`, both PreToolUse hooks allow every read through unchecked. See the `/toggle-hooks` skill for A/B testing hooks-on vs hooks-off. |
| `SHUNT_OPENCODE_CONFIG_HOME` | `~/.config/opencode` | Where to read your real OpenCode agent/provider config from, when building the isolated per-call config below. |
| `SHUNT_ISOLATED_CONFIG_DIR` | `~/.cache/agent-model-shunt/opencode-config` | Where the isolated, minimal OpenCode config (one agent, one provider) is written and reused for every delegated call. Safe to delete; it's regenerated on each `opencode run`. |
| `SHUNT_DEBUG_LOG` | unset | When `1`/`true`/`yes`, every real `scripts/bulk-read` call appends its usage to `SHUNT_DEBUG_LOG_PATH`. See the `/usage-report` skill and `scripts/usage-report`. |
| `SHUNT_DEBUG_LOG_PATH` | `~/.cache/agent-model-shunt/usage.jsonl` | Where `SHUNT_DEBUG_LOG` writes its JSONL usage records. |
| `SHUNT_MODELS_FILE` | `~/.config/agent-model-shunt/models.json` | Multi-model registry (see above). Its absence is the legacy-mode detection point. |
| `SHUNT_AGENTS_DIR` | `~/.config/agent-model-shunt/agents` | Where `scripts/shunt-models` materializes one OpenCode agent file per registered model. |
| `SHUNT_BREAKER_STATE_FILE` | `~/.cache/agent-model-shunt/breaker-state.json` | Per-model failure counts / cooldown timestamps. Safe to delete to reset all breakers. |
| `SHUNT_BREAKER_CONFIG_FILE` | `~/.config/agent-model-shunt/breaker-config.json` | Threshold/cooldown overrides, written by `scripts/shunt-breaker-config`. |
| `SHUNT_BREAKER_THRESHOLD` | `3` | Env override for consecutive failures before a model's breaker opens; takes precedence over the config file. |
| `SHUNT_BREAKER_COOLDOWN_SECONDS` | `300` | Env override for how long a model stays paused once its breaker opens; takes precedence over the config file. |
| `SHUNT_BREAKER_UNREACHABLE_COOLDOWN_SECONDS` | `120` | Like `SHUNT_BREAKER_COOLDOWN_SECONDS`, but for a model that failed as "unreachable" (no connection within `SHUNT_CONNECT_TIMEOUT`, or no route to the host). The config file field is `unreachable_cooldown_seconds`. The threshold is the same as for other failures. |
| `SHUNT_CONNECT_TIMEOUT` | `5` | `http` transport only: seconds the TCP connect (and TLS handshake) may take, a non-negative number. `0` means only `SHUNT_TIMEOUT_SECONDS` applies. A connect that does not finish fails fast as "unreachable" (`shunt: <model> unreachable: no connection within Ns`) and the next model is tried, so a sleeping laptop no longer costs a whole request timeout. It has no effect when it is not shorter than the request timeout. A model that connects but answers slowly is still a plain timeout. |
| `SHUNT_HEALTHCHECK_TIMEOUT` | `3` | `http` transport only, for providers with `"healthcheck": true`: seconds the pre-flight `GET <base_url>/models` may take (the completion probe has its own timeout below), a non-negative number. `0` disables the check. |
| `SHUNT_HEALTHCHECK_MODEL_TIMEOUT` | `30` | `http` transport only, for providers with `"healthcheck": true`: seconds the one token completion probe may take, a non-negative number. `0` skips that step. |
| `SHUNT_HEALTHCHECK_TTL` | `600` | Seconds a healthy status is trusted before a background probe refreshes it, a non-negative number. `0` starts a probe on every call. A request never waits for it. |
| `SHUNT_HEALTHCHECK_RETRY` | `30` | Seconds an unhealthy status fails calls over at once (the "tick"). After that the model is tried again by the real call and a probe. `0` never fails over on the status. |
| `SHUNT_HEALTHCHECK_INLINE` | unset | Tests only: `1` runs the background probe inside the calling process instead of a detached child. |

## Management skills

`/bulk-reader` and `/code-writer` (documented above) do the actual
delegation. These four skills manage shunt itself: the model registry,
the hooks, and delegate-spend visibility. Their work is mechanical (run a
script, show its result, ask what to change), so each one pins `model: haiku`
in its frontmatter and runs on Haiku whatever model the session uses. The two
delegation skills are not pinned: their real work already runs on the
delegate model.

- **`/model-config`**: dashboard and editor for the model registry, the
  circuit breaker, and the code-write self-fix retry count. Configuring
  delegate models is easiest done through this skill, never by
  hand-editing `models.json`, `breaker-config.json`, or
  `code-write-self-fix-config.json` directly.
- **`/toggle-debug-log`**: turns the `SHUNT_DEBUG_LOG` usage-tracking env
  var on/off. Needed before `/usage-report` has anything to summarize.
- **`/toggle-hooks`**: turns the `PreToolUse` hooks (`check-file-size`,
  `check-bash-read`) on/off, for A/B testing delegated vs. direct reads.
- **`/usage-report`**: summarizes actual delegate spend (tokens/cost) and
  the estimated Claude-context tokens avoided by delegating.

## Evals

```bash
evals/run.sh                # hook routing decisions, no network needed
evals/transport-evals.sh    # one live scripts/bulk-read call, needs OpenCode + a provider
evals/benchmark.sh          # token-savings + latency of the delegated OpenCode call, in isolation
evals/baseline-benchmark.sh # shunt vs Claude reading the files directly, needs OpenCode + a provider + `claude` CLI
evals/fidelity-benchmark.sh # does delegating lose information or hallucinate? Needs OpenCode + a provider + `claude` CLI
```

`evals/benchmark.sh` measures, per scenario in `evals/benchmarks.json`:

- **Token savings**: a `chars/4` estimate (the same conservative heuristic
  shunt uses) of the raw file content Claude would otherwise read, versus
  the delegated model's answer that lands in Claude's context instead.
- **Latency**: wall-clock time for the delegated round trip (see
  [Performance](#performance) for measured numbers per transport).
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
`claude -p --output-format json` call twice: once as a brand-new session
(`no-resume`) and once chained into the same session as the prior scenario
(`resume`, so the one-time cost of priming this project's system prompt is
only paid once, matching how a real interactive session amortizes it).
Then it runs the same scenario through `scripts/bulk-read` (`shunt`) and
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
session relayed it). It does not include the tokens a real session would
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

> **On speed:** the timing numbers in that ledger (and in
> `docs/fidelity-ledger.html`) depend heavily on which OpenCode provider and
> model you point `scripts/bulk-read` at. Different providers/models can be
> dramatically faster or slower for the same call. These numbers are one
> personal observation from one provider/model at one point in time, not a
> guarantee; re-run the benchmarks against your own setup before drawing
> conclusions about your own flow.

> The fixtures moved to real `labstack/echo` source (see above); the
> ledger and the results file it's built from need a fresh
> `evals/baseline-benchmark.sh` run against them before the numbers are
> trustworthy again. That run spends real money on your Claude account,
> so it isn't run automatically as part of an edit.

| Variable | Default | Purpose |
|---|---|---|
| `SHUNT_BASELINE_MODEL` | `sonnet` | Model alias passed to `claude -p --model` for the baseline side of `evals/baseline-benchmark.sh`. |
| `SHUNT_BASELINE_TIMEOUT` | `300` | Timeout (seconds) for each baseline `claude -p` call. |
| `ITERATIONS` | `3` | Repeats per scenario/variant in `evals/baseline-benchmark.sh`. Total `claude -p` calls = `ITERATIONS * 3 scenarios * 2` (no-resume + resume). |

### Fidelity: does delegating lose information or hallucinate?

`evals/baseline-benchmark.sh` answers "is delegation worth it" (cost/time).
`evals/fidelity-benchmark.sh` answers a different question: "does delegation
actually degrade the answer?" It runs against a separate ground-truth set,
[`evals/fidelity-questions.json`](evals/fidelity-questions.json), a list of
questions over the same `evals/fixtures/echo/` files, each with a
`ground_truth.must_mention` list of exact identifiers extracted mechanically
(`grep`) from the real source, not written from memory. Some questions are
marked `adversarial: true`: picked because a summarizing delegate is likely
to drop or flatten at least one item (inconsistent naming, less-common
identifiers, entries defined far from a file's main cluster).

For each question it captures three answers: `direct` (Claude reads the file
content inlined in the prompt), `delegate` (`scripts/bulk-read`'s raw
answer, which Claude never sees the source for), and `final` (Claude
answering the same question using *only* the delegate's raw answer, which
is what a real user actually sees once the `PreToolUse` hook blocks a direct
read and Claude falls back to bulk-read). Scoring is exact/structured, not
LLM-judged: recall is the fraction of `must_mention` items found as a
case-insensitive substring of the answer. An item counts as an
**unsupported claim** (a hallucination signal) if it shows up in `final` but
not in `delegate`'s own raw text, the only source `final` had. This is a
heuristic, not proof of fabrication: Claude can paraphrase a delegate claim
in different wording and trip a false positive, so treat unsupported claims
as something to inspect, not a final verdict.

Results go to `evals/results/fidelity-benchmark.jsonl`;
`evals/aggregate-fidelity-results.py` (run automatically at the end) prints
a per-question table of direct vs. delegate recall, which ground-truth
items each path dropped, and any unsupported claims. Like
`baseline-benchmark.sh`, this spends real money on your Claude account and
needs a reachable OpenCode provider. Run it deliberately, not in a loop.

**[`docs/fidelity-ledger.html`](docs/fidelity-ledger.html)** is the write-up
of the latest `evals/fidelity-benchmark.sh` run: on the current question
set (n=1), delegation showed 100% recall on every question, including the
adversarial ones, and zero unsupported claims.

## Development

Running the plugin needs only `bash` and Python 3.11+. The tests are in two layers.
`test/py` (pytest) is the main suite: it covers the Python core and also runs the
real launchers and hooks. The bats files in `test/` are shell-level smoke tests only
(hook stdin/stdout JSON and exit codes, launcher argv passthrough, the `BASH_ENV`
no-leak rule, bash 3.2 compatibility), plus the bash dev tooling in `evals/`.

- `pytest` for `test/py`. Without a virtualenv:
  `uv run --no-project --with pytest python -m pytest test/py -q`.
- [bats-core](https://github.com/bats-core/bats-core) with `bats-support` and
  `bats-assert`, plus `jq` (the bats tests build and check JSON with it) and GNU
  `parallel` for `bats -j`.
- Docker, optional, for the pinned images in `test/` (`make test`,
  `make test-bash32` for the macOS system bash 3.2, `make test-py311` for the
  oldest supported Python). Every image runs both bats and pytest.

```bash
make test          # bats + pytest in Docker, or make test-local if Docker is missing
make test-local    # bats on the host, then pytest (in the py311 image if the host has none)
make test-py       # pytest on the host
```

CI runs `make test`, `make test-bash32`, `make test-py311` and a separate `pytest`
job on the runner's default Python.

Set `PYTHONDONTWRITEBYTECODE=1` when running tests from the repository, so no
`__pycache__` lands under `scripts/` or `hooks/`. The live evals in
[Evals](#evals) also need a configured provider and, for the baseline and
fidelity runs, the `claude` CLI.

## Scope

Calls go through a transport layer with two transports, chosen per provider:
a direct HTTP client and the `opencode` CLI as a subprocess. See
[ADR 0018](docs/adr/0018-direct-http-transport-alongside-opencode.md), which
supersedes [ADR 0002](docs/adr/0002-wrap-opencode-cli-not-http-client.md).
Key storage, oversize input and thinking options are in
[ADR 0019](docs/adr/0019-api-key-storage.md),
[ADR 0020](docs/adr/0020-context-window-and-oversize-handling.md) and
[ADR 0021](docs/adr/0021-thinking-options-apply-to-both-transports.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
