# Python port: decisions log

Decisions taken autonomously during the bash to Python port (ADR 0022), so
they can be reviewed after the fact. Newest at the bottom of each section.

## Process

- 2026-10-12. Each sub-phase (1 to 12) gets its own commit as soon as its tests
  pass, as the user authorized. Messages are a single line with no attribution.
- 2026-10-12. After every 3 sub-phases (3, 6, 9, 12) the main session runs two
  reviews over that span's diff: a code review (`ecc:code-reviewer` plus
  `ecc:python-reviewer` where Python changed) and an adversarial review whose
  goal is to break the change: edge cases, races, behavior drift from bash,
  secret leaks. CRITICAL and HIGH findings are fixed in a separate `fix:`
  commit before the next sub-phase starts.
- 2026-10-12. The project rule "do not start a new phase branch until the
  previous one is merged" conflicts with "finish everything". Resolution:
  phase branches are stacked. Phase B branches off the tip of phase A and so
  on, each branch is pushed with `-u` and a compare URL is reported (gh PR
  creation does not work with this token). The user merges in order A, B, C, D.
  If A changes after review, B is rebased onto it.
- 2026-10-12. This file is committed together with the sub-phase it belongs to,
  so it is visible on GitHub from the pushed branches.

## Sub-phase decisions
- 2026-10-12. Sub-phase 1: found Alpine 3.24.1 with Python 3.14.8 in `bats/bats:1.14.0` and Alpine 3.22.6 with Python 3.12.15 in the pinned `bash:3.2` image. Neither is 3.11, so the floor needs its own lane.
- 2026-10-12. Sub-phase 1: added `test/Dockerfile.py311` (`python:3.11-alpine` pinned by digest, Alpine 3.24.2, Python 3.11.17), with the bash 3.2 binary copied from the pinned `bash:3.2` image (both musl, needs `ncurses-libs`). It runs bats under bash 3.2 and pytest. New `make test-py311` and CI job `tests-py311`.
- 2026-10-12. Sub-phase 1: pytest in the 3.11 lane is `pip install pytest==8.3.4` (Alpine's `py3-pytest` targets the system python, not the image's 3.11). The other two lanes use `py3-pytest` from apk.
- 2026-10-12. Sub-phase 1: `make test-docker` and `make test-bash32` run pytest after bats via `--entrypoint pytest`. Added `make test-py` for a local run.
- 2026-10-12. Sub-phase 1: the plugin version is read from `.claude-plugin/plugin.json` at runtime (single source, no constant to drift). The `version` subcommand is tested against that file.
- 2026-10-12. Sub-phase 1: `check_python` is a pure function taking a version tuple so the gate is tested without an old interpreter. `shunt_main.py` uses no 3.11-only syntax.
- 2026-10-12. Sub-phase 1: `conftest.py` sets `sys.dont_write_bytecode` so in-process imports leave no `__pycache__` under `scripts/py`. The `-B` test checks that.
- 2026-10-12. Sub-phase 1: the missing-interpreter bats test expects exit 127 (`run -127`) instead of just non-zero, to avoid the bats BW01 warning.
- 2026-10-12. Sub-phase 1: ADR 0022 is listed in `docs/adr/README.md` as Accepted with Implemented "Partial", since only the scaffold exists.
- 2026-10-12. Sub-phase 2: `env.py` keeps the bash quirks instead of "fixing" them to XDG. Registries default to `$HOME/.config/agent-model-shunt` and `$HOME/.cache/agent-model-shunt` (XDG_CONFIG_HOME and XDG_CACHE_HOME are not read, as in bash). Only the orchestrator fragment dir honours `XDG_CONFIG_HOME` and only the OpenCode `auth.json` honours `XDG_DATA_HOME`. An empty variable counts as unset (`${VAR:-default}`). `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` and `XDG_STATE_HOME` are not read anywhere in `scripts/` or `hooks/` today, so no resolver exists for them.
- 2026-10-12. Sub-phase 2: `lockfile.py` is `fcntl.flock` on `<file>.lock` only, with no `mkdir` fallback (fcntl exists on Linux and macOS). Polling every 0.1 s with a non-blocking lock, lock file opened for append and created 0666 minus umask like bash `>>`, nested use in one process only counts depth, timeout raises `LockTimeout`. The nesting table is per process and not thread safe.
- 2026-10-12. Sub-phase 2: `jsonio.write_json_atomic` serializes before creating the temp file, writes `.<name>.XXXXXX` in the target dir, `fchmod`s to an explicit mode (default 0600, like `providers.json`), fsyncs, `os.replace`s, then fsyncs the directory best effort. Output is indented with a trailing newline. Parent dirs are created (`mkdir -p`).
- 2026-10-12. Sub-phase 2: `read_json` returns the default for a missing file and raises `JsonReadError` (path in the message) for unreadable, empty or invalid files, so callers can no longer swallow jq errors silently.
- 2026-10-12. Sub-phase 2: `SHUNT_PROVIDERS_LOCK_TIMEOUT` is parsed as a float and a garbage or negative value raises `EnvError`, where bash would fail in arithmetic.
- 2026-10-12. Sub-phase 3: `models.sh` keeps every public function name as a wrapper over `shunt_py models <subcommand>`, passing `SHUNT_MODELS_FILE`, `SHUNT_AGENTS_DIR` and `SHUNT_PROMPTS_DIR` as per-call env, because the bash variables may be unexported defaults. `--` precedes id arguments so an id starting with a dash is not read as an option.
- 2026-10-12. Sub-phase 3: kept in bash on purpose: the `[ -f ]` check in `shunt_models_available` (the legacy no-registry path stays free of interpreter starts), the role check in `shunt_models_candidates`, `shunt_models_role_known`, `SHUNT_MODELS_ROLES`, `SHUNT_MODELS_ROLES_JSON` (used by the jq in `dashboard.sh` and `shunt-models`) and `SHUNT_MODELS_SLUG_JQ` (used by `transport-http.sh`), until those files are ported. A pytest compares `ROLES` in Python with the bash array.
- 2026-10-12. Sub-phase 3: hot path cost. The Read hook now spends two interpreter starts (`available`, then `candidates`) where it spent a few jq starts, and `shunt_invoke_role_with_failover` pays one start per candidate for `agent_for` or `code_writer_agent_for`. Not merged into one call to avoid changing the hook and failover contracts. Revisit in sub-phase 10 when the failover loop is ported.
- 2026-10-12. Sub-phase 3: the private bash helpers `_shunt_models_agent_name_error`, `_sizing_error`, `_render_*` and `_write_agent` are gone (no caller outside `models.sh`). `_shunt_models_slug_core` and `_shunt_models_thinking_block` stay as wrappers because bats calls them.
- 2026-10-12. Sub-phase 3: `models.sh` contains no writer of `models.json`. The writers are `shunt_models_write` in `scripts/shunt-models` (also called from `scripts/lib/migrate.sh`), moving in sub-phase 6.
- 2026-10-12. Sub-phase 3: agent `.md` files are written with the new `jsonio.write_bytes_atomic` (temp file, fsync, `os.replace`, mode 0600 like `mktemp`). `write_json_atomic` now delegates to it with unchanged behavior. The agent name is checked against `[a-z0-9][a-z0-9-]*` before it becomes a path, as a safety net on top of validation.
- 2026-10-12. Sub-phase 3: malformed registry shapes that made jq fail silently are mapped to the same visible results: a missing or non-array `models`, or an entry that is not an object, skips the duplicate, roles and agent-name stages and ends in the sizing message `cannot read context_tokens and oversize_policy.`. `null` and `false` documents report "invalid JSON" (as `jq -e .` did). `models` given as an object (jq would iterate its values) is treated as unreadable.
- 2026-10-12. Sub-phase 3: the readers (`candidates`, `agent-for`, `thinking-*`) exit 2 with a `shunt:` stderr line on a missing or unreadable registry. The wrappers for `candidates` and `agent_for` still return 1 like the old `|| return 1`. `has_role` is false on an unreadable registry.
- 2026-10-12. Sub-phase 3: the only bats change is `shunt_models_candidates reads the registry with a single jq call`, which asserted on jq spawns. It now asserts that jq is not spawned at all. All other bats tests pass unchanged.
