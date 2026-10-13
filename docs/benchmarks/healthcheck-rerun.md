# Benchmark rerun: bash (v0.5.0) vs Python with connect timeout and healthcheck

Date: 2026-10-13. Old side is tag v0.5.0 (bash and jq, checked out into a temporary
worktree). New side is branch `feat/model-healthcheck` (Python core, connect timeout,
per-provider healthcheck, code-writer in one Python process). Both providers had
`"healthcheck": true` in the user registry. v0.5.0 accepted that field without any
change, so both sides used the real providers file.

This run is only partly complete. The Spark delegate (bootsman, deepseek-v4.1-flash)
went down during the run, so most Spark rows are missing. The mac delegate (qwen36)
completed in full. The outage itself is a useful measurement, see "Unreachable-delegate
behaviour".

## Method

- Same cases as `docs/benchmarks/python-port.md`: the 3 cases of `evals/benchmarks.json`
  and the 5 questions of `evals/fidelity-questions.json` (3 repetitions each), and 3
  code-write tasks (pytest, json, bash; 2 repetitions each). Only the delegate side was
  run (no Claude calls at all, so no Haiku/Sonnet/Opus was used).
- The code-write tasks are new small ones written for this run (a pytest file for a
  small text helper module, a JSON config, a bash script), so the code-write rows are
  comparable between the two sides but not with the previous report.
- Medians are reported. Each repetition runs the bash side then the Python side,
  one after the other, never in parallel on the same delegate.
- Each side had its own scratch breaker state, healthcheck cache, usage log and
  isolated OpenCode config dir. A copy of `models.json` listed only the delegate under
  test as enabled. Nothing under `~/.config/agent-model-shunt` or
  `~/.cache/agent-model-shunt` was changed.
- Timeout: 300 s per call for the normal runs, 120 s (`SHUNT_TIMEOUT_SECONDS` and
  `SHUNT_TOTAL_TIMEOUT_SECONDS`) for the unreachable and hung-delegate runs. The bash
  side adds a few seconds on top of the cap (about 133 to 136 s for a 120 s cap).
- Fidelity recall is the share of `must_mention` items found in the stdout. The
  code-write check is `ast.parse` for pytest, `json.load` for json and `bash -n`.
- Mac and Spark runs overlapped in time (different servers, same client machine).

## Results, mac/qwen36 (median wall ms, 3 repetitions; 2 for code-write)

| Case | bash ms | Python ms | bash tokens in/out | Python tokens in/out |
|---|---|---|---|---|
| bench, single-large-file | 70802 | 80377 | 9950 / 2909 | 9950 / 3120 |
| bench, source-plus-test | 15067 | 11952 | 9306 / 487 | 9306 / 455 |
| bench, multi-file-cross-read | 29152 | 11334 | 19313 / 934 | 19313 / 412 |
| fidelity, echo-http-methods | 2997 | 1408 | 9978 / 94 | 9978 / 40 |
| fidelity, echo-wrap-functions | 724 | 1612 | 9959 / 14 | 9959 / 53 |
| fidelity, cors-config-fields | 9230 | 9685 | 9311 / 295 | 9311 / 355 |
| fidelity, cors-test-function-names | 1369 | 1322 | 9294 / 44 | 9294 / 44 |
| fidelity, cross-file-exported-types | 2751 | 3341 | 19311 / 72 | 19311 / 118 |
| code-write, pytest | 14444 | 15747 | 1421 / 515 | 1421 / 637 |
| code-write, json | 4608 | 3900 | 761 / 128 | 761 / 128 |
| code-write, bash | 3994 | 3006 | 783 / 125 | 783 / 108 |

- Fidelity recall: 1.00, 1.00, 1.00, 1.00 and 0.96 for both sides on all five
  questions (the same item is missed on `cross-file-exported-types` by both).
- Code-write syntax pass: 6 of 6 for each side (the driver's first pytest check was
  wrong and was corrected by re-parsing the saved files; all pass).
- All 48 bulk-read and 12 code-write calls succeeded on both sides.
- The spread is wide. Examples: bash `source-plus-test` ran 37, 15 and 12 s, and bash
  `echo-wrap-functions` ran 22 s once and 0 s twice (first call after idle is slow).
  No ranking of the two sides is justified for cases within about 30 percent.

## Results, Spark (bootsman, deepseek-v4.1-flash)

Spark became unreachable partway through the first run. What was measured before that
(medians):

| Case | bash ms | Python ms | bash tokens in/out | Python tokens in/out |
|---|---|---|---|---|
| bench, single-large-file (3 reps) | 22773 | 24273 | 9864 / 1581 | 9864 / 1643 |
| bench, source-plus-test (3 reps) | 5098 | 5384 | 9033 / 411 | 9033 / 442 |
| bench, multi-file-cross-read (1 rep each) | 10058 | 285561 | 18836 / 364 | 18836 / 580 |

- The one Python `multi-file-cross-read` run took 285 s (the same stall of about 290 s
  that the previous report saw on `single-large-file`), after which Spark stopped
  answering. A single bash run was 10 s. One sample each, so this is not a ranking.
- Not measured for Spark: the five fidelity questions, the three code-write tasks, and
  repetitions 2 and 3 of multi-file-cross-read. A second full Spark attempt failed on
  its first call, because Spark was down.
- Earlier in the session, a tiny `bulk-read` question timed out on both sides against
  Spark (the healthcheck passed because `/models` answered, but completions hung). A
  later short probe of four calls (about 21 to 25 s each) worked on both sides, so
  that first hang was transient.

## Unreachable-delegate behaviour

Time to fail or fail over, one `bulk-read` per call, 120 s cap.

Real outage of Spark (no connection to the host), only Spark enabled, so no failover
was possible. Python has the healthcheck on, bash does not have the feature:

| Side | Time to report failure |
|---|---|
| bash (v0.5.0) | 135.9 s, 136.1 s (waits for the 120 s cap and then some) |
| Python | 3.1 s, 3.1 s |

After the first failure the breaker opens on both sides, and later calls are refused
at once (34 ms bash, about 100 ms Python).

Simulated unreachable Spark (provider copy pointing at `http://10.255.255.1:1/v1`,
mac/qwen36 enabled as failover target, mac was reachable). Time includes the
successful mac answer after failover:

| Variant | Call 1 | Call 2 | Failure reason shown |
|---|---|---|---|
| bash | 133.1 s | 133.4 s | "timed out after 120s" |
| Python, healthcheck on | 15.1 s | 13.2 s | "healthcheck failed: no answer in time", then "unreachable" |
| Python, healthcheck off | 18.0 s | 21.1 s | "no connection within 5s", then "unreachable" |

Most of the Python times are the mac answer itself (about 10 to 15 s for this case), so
the cost of detecting the dead delegate is about 3 s with the healthcheck and about 5 s
without it (the connect timeout). Bash waited the full 120 s for a host that never
answered the connection. Call 2 shows no benefit from the breaker pause on either side
here because the unreachable pause is short and the second call retried the delegate.
The healthcheck variant was slightly faster to fail than the connect timeout alone, as
designed, though with two samples the 13 to 21 s totals are mostly mac time.

The mac laptop was awake for the whole run, so a real sleeping-mac case was not
measured. The Spark outage and the simulation stand in for it.

## Differences vs the previous report

- The previous report could not measure mac (first call timed out after 300 s and the
  breaker then opened). Now mac is complete, 48 of 48 bulk calls and 12 of 12
  code-write calls on each side.
- Spark is now the incomplete delegate, for the same kind of reason (it stopped
  answering). The previous Spark medians were not reproduced for the fidelity and
  code-write rows.
- Connect timeout and healthcheck are new: the Python side fails over in about 3 to 5 s
  where the bash side waits for the full timeout.
- Latency on healthy delegates is again mixed. Python is faster on five mac rows
  (multi-file-cross-read by 61 percent), slower on four, level on the rest, with large
  run-to-run spread.
- Token counts match between sides (identical input tokens, output tokens vary with
  model sampling).
- The code-write tasks differ from the previous report's tasks.

## Not measured

- Spark fidelity, Spark code-write, and Spark repetitions beyond those listed (Spark
  down).
- A real sleeping mac laptop (it stayed awake).
- Offline hook and refusal timings: skipped, the previous script is not in the repo and
  a quick substitute would not be comparable.
- Claude's own token spend, process launch counts (no container or strace this time).
- The 100 percent healthy-Spark comparison for the healthcheck overhead on a
  reachable provider: the healthcheck adds one `/models` request per provider per 60 s
  TTL, which was not isolated as a number.
- The bats and pytest suites were not run, by instruction.
