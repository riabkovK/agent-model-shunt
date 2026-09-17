# TODO

## Fidelity eval: does delegating a read lose information or introduce hallucination?

`evals/baseline-benchmark.sh` measures cost and latency, not correctness. It
never checks whether Claude, working from the delegate's answer instead of
the raw file, ends up wrong or missing something a direct read would have
caught. This section plans that check; nothing below is implemented yet.

- [ ] Build a ground-truth question set over `evals/fixtures/*.ts`: questions
      with a single verifiable correct answer (exported symbol names,
      function signatures, which test covers which behavior), checkable by
      grep/AST rather than subjective grading.
- [ ] Include adversarial questions targeting details a summarizing delegate
      model is likely to drop or flatten (a condition buried in one line, an
      edge case, an off-by-one in a loop bound) — the goal is to catch
      information loss specifically, not general model capability gaps.
- [ ] For each question, run both paths and capture the answer:
      (a) Claude reads the fixture file directly and answers;
      (b) `scripts/bulk-read` answers, and that answer (not the file) is
      what Claude is given to answer from.
- [ ] Score both paths against the ground truth (exact/structured match
      where possible, not another LLM's judgment call, to avoid coupling the
      grader's own failure modes to the thing being measured).
- [ ] Separately flag cases where Claude's final answer states something not
      present in the delegate's answer — a direct signal of hallucination
      added on top of a compressed context, distinct from the delegate
      itself being wrong.
- [ ] Package as `evals/fidelity-benchmark.sh` (or similar), following the
      existing evals' pattern: fixed fixtures, a results JSONL, an
      aggregator script, real cost printed up front since it's another
      real-`claude -p` benchmark.
- [ ] Write up findings in `docs/shunt-ledger.html` (or a new
      `docs/fidelity-ledger.html`) once there's a real run to report.

## Distribution: push to GitHub, own marketplace, easy install for users (done 2026-09-16)

Right now the repo only has `.claude-plugin/plugin.json` (a single-plugin
manifest), not a `.claude-plugin/marketplace.json`. That's enough for local
dev but not for a real user to install this with one command, or to
disable/update it later.

- [x] Push this repo to GitHub (`riabkovK/agent-model-shunt`, per
      `plugin.json`'s `repository`/`homepage` fields, which already point
      there). Done as part of the rename phase (2026-09-16).
- [x] Add a `.claude-plugin/marketplace.json` at the repo root listing this
      plugin. Done as part of the rename phase (2026-09-16).
- [x] Document the one-command install path for end users in the README:
      `claude plugin marketplace add riabkovK/agent-model-shunt` (GitHub
      shorthand, no clone needed) or a local path, then `claude plugin
      install agent-model-shunt@agent-model-shunt-marketplace`. Done
      2026-09-16.
- [x] Verify and document disable/update flows in the README: third-party
      marketplaces don't auto-update by default, so `claude plugin
      marketplace update agent-model-shunt-marketplace` (or the auto-update
      toggle under `/plugin` → Marketplaces) picks up new commits;
      `claude plugin disable/enable ...@...` toggles without uninstalling;
      `claude plugin uninstall ...@...` removes it entirely. Verified via
      claude-code-guide lookup, not guessed. Done 2026-09-16.

## Multi-model support + circuit breaker

Right now `SHUNT_BULK_READER_AGENT` points at exactly one hand-written
OpenCode agent (`~/.config/opencode/agents/bulk-reader.md`, one `model:`).
This section plans letting shunt rotate across several delegate models
instead of being pinned to one, with automatic failover when a model is
erroring. Grilled out with the user on 2026-09-15; nothing below is
implemented yet.

Implementation plan drafted by the planner agent on 2026-09-16 (branch
`phase/multi-model-support`): registry (`models.json`) + agent
materialization, circuit breaker state, failover wiring, thinking-off
default, `/model-config` skill, docs/ADRs — one commit per sub-phase.
Test tooling decision (2026-09-16): bats-core (+ bats-support, bats-assert),
not a hand-rolled `evals/unit-run.sh` — needs `sudo pacman -S bats
bats-support bats-assert` (not yet installed; implementation starting
without tests, bats suite to be added once installed).
Breaker exhaustion behavior (2026-09-16, overrides the plan's D3
recommendation): when the active model's breaker is open and no other
model in `models.json` is available, do NOT hard-fail the delegated call.
Instead `hooks/check-file-size` must allow the direct `Read` (skip the
deny) so Claude reads the file itself unrestricted — same as if
`SHUNT_HOOKS_DISABLED` were set for that one call. This needs the hook to
consult breaker/registry state before denying, which pulls hook changes
into Phase 3 (failover wiring) rather than leaving them out of scope.

- [ ] Add a shunt-owned `models.json` (e.g.
      `~/.config/agent-model-shunt/models.json`): a priority-ordered list of
      `provider/model` strings, the source of truth for which delegate
      models exist and in what order they're tried.
- [ ] Build a config skill that edits `models.json` (add/remove/reorder) and,
      for each model added, materializes a lightweight OpenCode agent file
      for it (same shape as today's `bulk-reader.md`) once at edit time, not
      regenerated on every `scripts/bulk-read` call. The skill is also how a
      user manually picks which model in the list is currently active.
- [ ] Add a circuit breaker, separate from model selection, scoped only to
      failures (errors/timeouts), not latency: N consecutive failures on the
      active model opens the breaker and excludes it for a cooldown period,
      after which it's retried automatically. No response-time measurement
      and no racing multiple models concurrently — both considered and
      explicitly ruled out as unnecessary complexity for v1.
- [ ] Persist circuit breaker state (failure counts, cooldown timestamps per
      model) in a state file next to the isolated per-call OpenCode config
      (see `SHUNT_ISOLATED_CONFIG_DIR`), since every delegated call is its
      own short-lived `opencode run` process with no shared memory between
      calls.
- [ ] Wire automatic failover: when the active model's breaker is open and
      another model in `models.json` is available, shunt uses the next
      one in priority order instead of failing the call outright.
- [ ] For delegate models that support a "thinking"/extended-reasoning mode,
      default it OFF (bulk-read is a summarize/extract task, not deep
      reasoning, and thinking tokens cost time and money without a clear
      fidelity benefit per the fidelity-eval results above). Let the user
      turn it back on per-model via a dedicated yes/no question in the
      model-config skill (the same skill that edits `models.json`), not a
      global switch. Added to scope 2026-09-16 per user request.

## Rename off the `cc-` prefix, widen scope framing to multi-host (done 2026-09-16)

The `cc-` prefix in the old `cc-model-shunt` name tied the project to Claude
Code specifically. Codex support is a real near-term plan, not just
future-proofing, so the name needed to stop implying a single host before
that work starts. Grilled out with the user on 2026-09-15/16; completed
2026-09-16 on `phase/rename-agent-model-shunt`.

- [x] Renamed the project to `agent-model-shunt` across all text
      references: `README.md`, `.claude-plugin/plugin.json` (`name`,
      `homepage`, `repository`, `author.name`), `.claude-plugin/marketplace.json`
      (`name`, the plugin entry's `name`), `skills/toggle-debug-log/SKILL.md`,
      `skills/usage-report/SKILL.md`, `docs/adr/README.md`,
      `.claude/CLAUDE.md`, and the `LICENSE` copyright line.
- [x] Renamed the GitHub repo `riabkovK/cc-model-shunt` →
      `riabkovK/agent-model-shunt` (`gh repo rename`), and updated
      `plugin.json`'s `homepage`/`repository` and `marketplace.json` to the
      new URL rather than relying on GitHub's redirect.
- [x] Migrated the cache paths in `scripts/lib/opencode.sh`
      (`SHUNT_ISOLATED_CONFIG_DIR`, `SHUNT_DEBUG_LOG_PATH` defaults) and
      `scripts/usage-report` from `~/.cache/cc-model-shunt/...` to
      `~/.cache/agent-model-shunt/...`. Dev-only at the time, so no
      migration script was needed for old cache data.
- [x] Rewrote the top-line description (README's opening paragraph,
      `plugin.json`'s `description`, `marketplace.json`'s plugin
      `description`) to tool-agnostic framing that still names the current
      concrete implementation.
- [x] Added [ADR 0009](docs/adr/0009-multi-host-scope-shift.md), which
      supersedes-in-part [ADR 0003](docs/adr/0003-claude-code-only-scope.md):
      0003 stays `Accepted` (the plugin format is still Claude-Code-specific
      by design and a real adapter layer is still needed for other hosts),
      but 0009 records the scope shift from "Claude Code only, no other
      hosts" to "Claude Code first, other hosts (Codex) planned."
- [x] Distribution section below now reflects the new
      `agent-model-shunt@...` install name.

## Backlog, not designed yet

- [ ] `code-writer` (delegated boilerplate generation, as in Spotify's
      `shunt`) — expands scope past the MVP's bulk-read-only boundary (see
      [ADR 0006](docs/adr/0006-mvp-scope-bulk-read-only.md)). Needs its own
      design pass, including how to safely scope write/edit permissions for
      a delegated model.
- [ ] Direct HTTP client against a provider instead of wrapping the
      `opencode` CLI (see
      [ADR 0002](docs/adr/0002-wrap-opencode-cli-not-http-client.md)). Also
      needs its own design pass.
