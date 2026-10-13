# Benchmark: bash core (v0.5.0) vs Python port

This report compares the last bash release (v0.5.0, tag commit `c115d81`) with the
Python port on branch `feat/python-port-finish`. It covers latency, delegate token
counts, output fidelity, the Claude context footprint and the number of program
launches. Raw numbers come from two runs: an offline run (no network, no model
calls) and a live run against the Spark delegate model. The mac delegate could not
be measured, see "Not measured".

## Method

- Offline: the hooks, `bulk-read` and `code-write` refusal paths, `session-start`
  and the SKILL.md size, with a local stub for the delegate. Mean of repeated runs.
- Live: `evals/benchmarks.json` cases (3 repetitions) and the code-write tasks
  (2 repetitions) through the real delegate `bootsman/Spark/deepseek-v4.1-flash`.
  Medians are reported because single runs vary a lot.
- Process counts: `execve` calls counted under `strace` in an Alpine container.
- Only Haiku was used as Claude's model in the tests. The benchmark did not call
  Opus.

## Offline results (mean, ms)

| Case | bash | Python |
|---|---|---|
| check-file-size, pass-through | 6.5 | 9.3 |
| check-file-size, refusal | 20.9 | 28.4 |
| check-bash-read, pass-through | 3.6 | 9.2 |
| check-bash-read, refusal | 5.2 | 9.4 |
| session-start, with registry | 32.0 | 30.6 |
| session-start, no registry | 3.9 | 30.0 |
| bulk-read, 100 KB | 73.9 | 100.9 |
| bulk-read, 40 KB | 72.8 | 101.2 |
| bulk-read chunked, 100 KB | 234.6 | 143.2 (-39%) |
| bulk-read chunked, 40 KB | 154.7 | 119.5 (-23%) |
| code-write | 141.2 | 103.6 (-27%) |
| code-write refusal | 19.7 | 96.0 |

## Live results, Spark delegate (median of repetitions)

| Case | bash ms | Python ms | bash tokens in / out | Python tokens in / out |
|---|---|---|---|---|
| bench, single-large-file | 35669 | 59246 | 9902 / 1355 | 9864 / 1629 |
| bench, source-plus-test | 14589 | 14795 | 9109 / 396 | 9033 / 420 |
| bench, multi-file-cross-read | 9246 | 11760 | 18950 / 350 | 18836 / 439 |
| fidelity, echo-http-methods | 2970 | 2112 | 9931 / 35 | 9893 / 35 |
| fidelity, echo-wrap-functions | 1022 | 1989 | 9912 / 11 | 9874 / 49 |
| fidelity, cors-config-fields | 7179 | 5107 | 9114 / 238 | 9038 / 243 |
| fidelity, cors-test-function-names | 1388 | 1682 | 9096 / 41 | 9020 / 41 |
| fidelity, cross-file-exported-types | 2614 | 2048 | 18948 / 106 | 18834 / 49 |
| code-write, pytest | 6665 | 6897 | 1290 / 351 | 1289 / 314 |
| code-write, json | 4128 | 3034 | 738 / 174 | 737 / 158 |
| code-write, bash | 4057 | 3718 | 721 / 182 | 720 / 176 |

Single runs are noisy. One Python run of `single-large-file` took 293 s, and
the bash run of the same case took 30 s to 69 s. The median of the three Python
runs is still 59 s, so the Python path is not faster for that case, but the
spread is too wide to rank the two with confidence. Medians on the smaller cases
differ by a few seconds in both directions.

## Fidelity and context

- The refusal texts and the `bulk-read` stdout are byte-identical between bash and
  Python (checked offline).
- The SessionStart context is 1 byte longer in Python (one newline).
- SKILL.md grew from 29554 B to 29905 B, that is +351 B, roughly 88 tokens of
  Claude context spent on each load of the skill.
- Live fidelity recall against `must_mention` (5 questions, 3 runs each) is 1.00
  for both bash and Python, so it does not tell the two apart.
- Live code-write: 6 of 6 results pass the syntax check (py_compile, jq, bash -n)
  for both implementations.

## Process launches (`execve` count)

| Case | bash | Python |
|---|---|---|
| hooks | 6 to 19 | 2 |
| session-start, with registry | 41 | 2 |
| bulk-read | 63 to 67 | 2 |
| bulk-read, chunked | 222 | 2 |
| code-write | 120 | 2 |

## Not measured

- mac/qwen36: the first live call timed out after 300 s. The circuit breaker then
  opened, and every later mac call was refused without running. The breaker state
  was not reset, because it is runtime state of the user's installation. The mac
  rows are therefore empty. Rerun them after the breaker closes.
- The live run did not measure Claude's own token spend. Use `/cost` for that.

## Usage log (`scripts/usage-report`)

Totals from the current usage log: 153 calls, 2,292,891 delegate input tokens,
228,348 delegate output tokens, delegate cost $0 (local models), and an estimated
1,264,627 context tokens kept out of Claude's reads (chars/4). `code-write` output
kept out of Claude's writes is estimated at 80,283 tokens. The log does not
separate benchmark calls from real work, so these totals include both.

## Conclusions

- Latency: the Python port is slower for the cases that are short anyway. The
  refusal path of `code-write` costs about 96 ms against 20 ms in bash, because
  the whole package is imported before the refusal. The hooks cost 3 to 10 ms
  more each. Session start without a registry is about 26 ms slower.
- Latency for the heavy paths is equal or better in Python: chunked `bulk-read`
  is 23 to 39 percent faster offline, and `code-write` is 27 percent faster
  offline and 10 to 25 percent faster live in the medians.
- Launches drop from dozens per call to 2. This is the clearest gain, and it
  matters most on Windows and macOS where a process launch is expensive.
- Token counts on the delegate side are the same within 1 to 2 percent.
- Context cost is +88 tokens for the longer SKILL.md and +1 byte for SessionStart.

## Recommendations

1. Import the code-write modules lazily, so a refusal does not import the whole
   package. This should bring the refusal path close to bash's 20 ms.
2. Keep the hook fast path small: only import `shunt.hooks` when a rule can match.
3. Repeat the mac/qwen36 live run after the breaker closes, with at least 3
   repetitions.
4. Report medians and spread, not means, for live runs.
