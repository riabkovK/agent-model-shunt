# 0017: `code-write` write boundaries, and the residual TOCTOU risk accepted for v1

## Status

Accepted

## Context

`code-write` writes a model-influenced file to disk on Claude's behalf,
using the `Bash` tool rather than the `Write` tool. That path skips Claude
Code's own per-`Write` permission prompt, so the script itself has to be the
thing that refuses an unsafe target, before any content is generated. All of
the checks below run before the model is called; none of them touch the
circuit breaker, since a refusal here is not a delegate failure.

## Decision

**Project root.** `$CLAUDE_PROJECT_DIR` if set, else `git rev-parse
--show-toplevel`, else the current directory. Verified in sub-phase 2:
`CLAUDE_PROJECT_DIR` is not exported to commands the `Bash` tool runs (only
to hooks), so in practice the root is always the git toplevel or the cwd;
the environment-variable branch is kept for the hook-invoked case.

**Path validation**, in order: split `--target` into path components; any
`..`, `.`, or empty component is refused outright. Find the nearest
ancestor directory that already exists, `realpath` it, and require the
result to be strictly inside the project root — a symlink that resolves
outside the root is refused the same as a literal path outside it.

**Denylist by path component**, checked over the full target path including
components that do not exist yet: `.git`, `.claude`, `.github`, `.env*` and
similar credential/config dotfiles (`.ssh`, `.aws`, `.azure`, `.gnupg`,
`.kube`, `.netrc`, `.npmrc`, `.pypirc`, `.docker`, and equivalents), plus
`.gitmodules`, `.gitattributes`, `.mcp.json`, `.htpasswd`, and named files
`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`, `Jenkinsfile`,
`opencode.json`, `Makefile`, `GNUmakefile`, `justfile`, `Rakefile`,
`Vagrantfile`, and `conftest.py`. `.gitignore` is explicitly allowed. The
match is case-insensitive (C locale) and ignores trailing dots and spaces,
since Windows treats `.git.` the same as `.git`. Any of these must be
written by Claude itself with the `Write` tool, which does ask for
permission.

**Directory creation and publish.** `mkdir -p` runs only after a successful,
validated model response (a failed or refused call leaves no empty
directories behind), and only for components inside the root and outside
the denylist; if the later write fails, only the directories this call
itself created are removed, and only if still empty (`rmdir`, best effort).
The file itself is written to a temp file in the target's own directory,
then published with a no-clobber primitive (`ln`, falling back to `mv -n`)
so a concurrent check-then-write race cannot silently overwrite something
that appeared between the check and the write. File mode is fixed at
`0644`; the execute bit is never set. The result is capped at about 256KB
and refused if it contains a NUL byte or is not valid UTF-8.

**Accepted residual risk: TOCTOU via directory-to-symlink substitution.** If
something replaces one of the target's parent directories with a symlink in
the brief window between the ancestor-resolution check and the actual
`mkdir`/publish, the write could land outside the validated root. This is
accepted for v1: closing it fully would need atomic `openat`-family
directory-fd operations that Bash's `mkdir`/`ln` do not expose, for a race
window an attacker would need local write access to the working tree to
exploit in the first place — at which point they already have easier ways
to cause damage.

**Fence-stripping trade-off.** Only an outer markdown fence wrapping the
entire `SHUNT-CODE` body is stripped (see
[ADR 0015](0015-code-write-create-only-and-tag-protocol.md)); inner fence
lines are preserved. The agent's prompt tells the model not to wrap its
answer in an outer fence and to use four backticks for any fence nested in
Markdown content it generates. The accepted trade-off is that a model which
ignores this instruction and emits a real leading/trailing fence line as
*content* (not as wrapping) will have that line stripped incorrectly; this
is judged a rare, non-security failure mode caught by the mandatory
post-generation review in `skills/code-writer/SKILL.md`, not something worth
a more complex fence parser for v1.

**Signal handling.** `trap shunt_cw_cleanup INT TERM HUP` removes the
script's own temp file on a caught signal. A `.shunt-cw.*` temp file can
still be left behind if the process is killed with a signal the trap cannot
catch (`KILL`, or a crash), or if a caller invokes the library functions
directly without installing the same trap; a stray file with this prefix in
a target directory is safe to delete manually.

**No Unicode-lookalike defense.** The denylist match is a literal,
case-folded string compare. It does not detect zero-width characters,
fullwidth Unicode variants, or other lookalikes of `.git`, `.claude`, or the
named denylisted files that a sufficiently adversarial `--target` argument
could use to visually resemble a denied name while not literally matching
it. This is accepted for v1: the realistic threat model is Claude choosing a
target path, not an adversary crafting one, and Unicode normalization adds
meaningful complexity for a threat not present in the actual usage pattern.

## Consequences

- Every refusal in this ADR happens before the model is ever called, so a
  bad `--target` costs no delegate tokens and never touches the circuit
  breaker's failure count.
- The TOCTOU and Unicode-lookalike gaps are documented, known limitations,
  not silent ones; revisiting either is a new decision, not a bug against
  this ADR.
- `test/codewrite.bats` exercises the security-relevant cases first: `..`
  segments, a symlink pointing outside the root, a symlink substituted
  partway through the path, an existing file/dir/symlink at the target, a
  denylist hit on a not-yet-created component, and the no-clobber publish
  race.
</content>
