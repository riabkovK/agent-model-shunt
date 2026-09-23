---
name: code-writer
description: Delegate generating ONE NEW file (test, config, stub, docstring-heavy boilerplate) to a custom model via OpenCode, saving Claude's own output tokens on predictable generation. Use when about to write a brand-new file from scratch. Not for editing existing files.
---

# Code Writer

Delegates the generation of a single new file to a custom user-configured
model (via OpenCode), so Claude's own output tokens are not spent on
predictable generation the delegate can produce just as well. Claude
reviews the result afterwards; review costs only input tokens.

> This file currently documents the call contract and the self-fix loop.
> Broader "when to delegate" decision criteria, the mandatory review
> checklist in full, and the project's ADRs for this feature land in a
> follow-up commit.

## How to call it

```bash
scripts/code-write --kind test|generic --spec "<what to generate>" \
  --reference <file>... [--source <file>...] [--rules <file>...] \
  [--allow-outside] --target <new file>
```

- `--kind test` requires `--source` (the code under test). `--kind generic`
  makes `--source` optional.
- `--reference` is always required (style/patterns to match).
- `--target` must not exist yet — this is create-only. Editing an existing
  file is out of scope; use `Edit`/`Write` directly instead.
- Exit 0: the file was created, its notes (if any) are on stdout. Exit 1:
  refused or failed, nothing was written. Exit 3: the model deliberately
  declined, nothing was written, read its notes.

## Mandatory post-generation review

After every successful call (exit 0), before treating the file as done:

1. Read `SHUNT-NOTES` (the script's stdout) for anything the model flagged
   as skipped, missing, or doubtful.
2. Read the new file's content (it is small — this is a normal `Read`, not
   a delegated one).
3. Run the project's own build/tests for it via normal Bash.
4. For a generated test file, read its assertions for real behavior checks,
   not just that it runs — a test that passes by asserting something
   vacuous is a failure of the whole exercise.

## The self-fix loop

A build/test failure at step 3 does not automatically mean falling back to
fixing the file by hand. First try the delegate again, since the failure is
usually a wrong hand-computed expected value in a generated test, not a bug
in the code under test.

**When it fires.** Only when you can name a mechanical verification command
for this exact target — a test runner (`go test`, `pytest`, ...) or a
compile/typecheck command (`go build`, `tsc --noEmit`, `python -m
py_compile`, ...). Decide this per call, not from a fixed table keyed on
`--kind` or file extension. If the target has no build and no test (prose,
Markdown, most config), there is no loop: verifying "generated wrong" vs.
"generated right" without one would require reading the whole file, which
spends the same input tokens code-writer exists to avoid. A file like that
only gets the manual review above.

**Verification is never a read.** Do not decide pass/fail by reading the
generated file's content. Always run the verification command as a Bash
subprocess and judge only its exit code and captured stderr/output.

**On failure:**

1. Delete the failed `--target`.
2. Call `code-write` again with the exact same arguments, except append the
   raw verification output (stderr/test failure text, verbatim, not
   summarized) to `--spec`. Do not paraphrase or shorten it yourself — the
   point of the loop is spending no Claude output tokens on this. `--spec`
   has its own size cap (32768 characters); if the raw output would exceed
   it, truncate the appended output, not the original spec.
3. Verify again (same command, same subprocess-only rule).

**How many times.** Check the current limit with
`scripts/shunt-codewrite-config show` (`self_fix_retries`, default 1,
global — see `/model-config`). Repeat the delete-and-recall step up to that
many times. `0` means never retry automatically.

**When retries are exhausted.** Any failure still standing after the
configured number of retries is Claude's to fix by hand, exactly as if the
loop did not exist. There is no attempt to classify "the same error" vs. "a
different error" — a hard retry cap makes that distinction unnecessary.

**The circuit breaker is untouched by any of this.** `scripts/lib/breaker.sh`
tracks protocol failures (errors, timeouts), never response quality. A
build/test failure here is a successful, on-protocol response that happens
to be substantively wrong — a different failure class the breaker
deliberately does not see. Only `code-write`'s own failure classification
(an unusable response: truncated, malformed tags, oversize, ...) touches
the breaker, self-fix retries never do.

## Configuration

- `scripts/shunt-codewrite-config` — the self-fix retry count. Drive it
  through `/model-config`, never by hand-editing
  `~/.config/agent-model-shunt/self-fix-config.json`.
- See the project README for the delegate model setup shared with
  `bulk-reader` (`/model-config`, `scripts/shunt-models`).
