# 0022: Port the core from bash and jq to Python

## Status

Accepted

## Context

[ADR 0004](0004-bash-jq-implementation.md) chose bash and jq. The core is now
about 5400 lines with 161 jq calls. The adversary review of the provider
commands found breaks that are mostly shell-specific: duplicated regex URL
validation, jq errors hidden by `2>/dev/null`, unlocked read-modify-write of
`providers.json`, and no schema for the registries. The orchestrator and user
skills add more config and logic, which makes this worse.

## Decision

Port the core to Python in 12 sub-phases on 4 phase branches (see
`docs/TODO.md`). The rules for the port:

- **Stdlib only, 3.11 floor.** No pip dependencies, no build step. pytest is a
  test-only dependency installed in the Docker images. macOS ships no usable
  python3, so macOS users need Homebrew python or any 3.11+ interpreter named
  in `SHUNT_PYTHON`.
- **Invocation is `python3 -I -B scripts/py/shunt_main.py <cmd>`.** `-I` ignores
  `PYTHON*` variables and user site dirs, `-B` keeps `__pycache__` out of the
  plugin dir. The runner checks the version first and exits 2 with a one-line
  error on an old interpreter.
- **Coexistence through wrappers.** A ported bash function keeps its name,
  stdout and exit code and becomes a thin wrapper around `shunt_py`
  (`scripts/lib/py.sh`). Callers and bats tests do not change while the port is
  in progress.
- **All writers of one JSON file move in the same sub-phase.** The bash `mkdir`
  lock and `fcntl.flock` do not exclude each other, so a file must never have a
  bash writer and a Python writer at once.
- **Keyring access stays CLI based.** Python calls `secret-tool`, `security` and
  friends as subprocesses, as bash does today (ADR 0019).
- **Hooks.** `hooks/check-bash-read` and the fast path of `hooks/check-file-size`
  stay bash to avoid interpreter startup on every tool call. The session hook
  moves to Python later.
- **The bats suite is the behavior oracle.** One approved exception: the fake
  `curl` is replaced by a local stdlib HTTP server once the HTTP client is
  ported, and the curl-argv assertions move to pytest.
- **jq leaves the runtime dependencies** when the last jq user is ported.

## Consequences

- Python 3.11 becomes a runtime requirement. CI covers the floor exactly with a
  `python:3.11-alpine` lane (`make test-py311`) next to the bash 3.2 lane.
- During the port both languages exist, and every wrapper is a temporary seam
  that is deleted with its bash body.
- ADR 0004 is marked superseded now that the port is complete (sub-phase 12c).
