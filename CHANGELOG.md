# Changelog

User-visible changes per release. Internal refactors are listed only when they
change what you install, configure or see.

## Unreleased (since v0.5.0)

Branches `feat/python-port-finish`, `feat/model-healthcheck` and `feat/retire-bash`.

### Requirements

- The core now runs on Python 3.11 or newer (standard library only, nothing to
  `pip install`). `bash` is still needed for the thin launchers.
- `jq`, `curl` and GNU `coreutils` are no longer needed at run time.

### Added

- Provider healthcheck for local servers (HTTP transport). Turn it on or off per
  provider in `/model-config` ("Healthcheck on/off"). New providers created
  through `/model-config` get it on by default.
  - It checks the model, not just the server: the model id must be listed in
    `GET <base_url>/models`, and a one-token completion must answer.
  - It runs in the background and never delays a request. Models are probed at
    session start and again when a healthy status is older than
    `SHUNT_HEALTHCHECK_TTL` (default 600 s).
  - A model found down is skipped at once and the next model is tried. After
    `SHUNT_HEALTHCHECK_RETRY` (default 30 s) it is tried again, so a model that
    only works behind a VPN comes back by itself on the next tick once the VPN is
    up.
  - For these providers a refused connection, an unknown host, a 404 or a 5xx
    marks the model unhealthy instead of opening the circuit breaker.
- `SHUNT_CONNECT_TIMEOUT` (default 5 s): a server that does not accept the
  connection fails fast as "unreachable" and the next model is tried, instead of
  waiting for the whole request timeout.
- `SHUNT_BREAKER_UNREACHABLE_COOLDOWN_SECONDS` (default 120 s): a shorter
  breaker pause for unreachable models.

### Changed

- `bulk-read`, `code-write`, the hooks and every `/model-config` command now run
  in one Python process each instead of a chain of bash, `jq` and `curl`.
- Entering a key in a terminal without a desktop (`shunt-models key set`) now
  prompts on the terminal itself (`/dev/tty`), not on stderr. Input stays hidden.
  The key window opened by `/model-config` is unchanged.
- A successful call now clears the circuit breaker of that model for every role.

### Removed

- The bash implementation of the core (`scripts/lib/*.sh` except the small
  launcher bridge `py.sh`). Commands, options, messages and exit codes are the
  same as before.

### Development

- `pytest` (`test/py`) is the main test suite. bats keeps only tests that need a
  real shell, launcher or hook process. `make test`, `make test-bash32`,
  `make test-py311` and CI run both.
- Fixed a hang of `bats -j 4` caused by background test processes holding an
  inherited file descriptor.
