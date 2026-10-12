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
