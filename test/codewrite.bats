load 'test_helper'

# Tests for scripts/lib/codewrite.sh: project root resolution, target
# validation, the response protocol parser and the no-clobber publish.
# Security cases come first on purpose.

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/codewrite.sh"

  unset CLAUDE_PROJECT_DIR SHUNT_CW_MAX_CODE_BYTES SHUNT_CW_MAX_NOTES_BYTES
  PROJ="$TEST_TMPDIR/proj"
  OUTSIDE="$TEST_TMPDIR/outside"
  mkdir -p "$PROJ" "$OUTSIDE"
  PROJ="$(cd -P "$PROJ" && pwd -P)"
  OUTSIDE="$(cd -P "$OUTSIDE" && pwd -P)"

  RESP="$TEST_TMPDIR/response.txt"
  OUT="$TEST_TMPDIR/parsed"
  CODE_IN="$TEST_TMPDIR/code-in.txt"
  mkdir -p "$OUT"
  printf 'hello\n' >"$CODE_IN"
}

teardown() {
  shunt_test_teardown
}

# Lists every path under the test tmpdir, so a test can prove that a refused
# call did not touch the disk.
snapshot() {
  (cd "$TEST_TMPDIR" && find . -print | LC_ALL=C sort)
}

# GNU stat first, BSD stat as the fallback so the suite also runs natively
# on macOS.
mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

link_count_of() {
  stat -c %h "$1" 2>/dev/null || stat -f %l "$1"
}

leftover_temp_files() {
  find "$TEST_TMPDIR" -name '.shunt-cw.*'
}

# assert_refused_target <target>: the check must fail with "refusing target"
# and must not change anything on disk.
assert_refused_target() {
  local before after
  before="$(snapshot)"
  run shunt_cw_check_target "$PROJ" "$1"
  assert_failure
  assert_output --partial "refusing target"
  after="$(snapshot)"
  [ "$before" = "$after" ]
}

# assert_parse_unusable <reason>: exit 11 and the given reason, and no
# output files left in $OUT.
assert_parse_unusable() {
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 11
  assert_output "$1"
  [ ! -e "$OUT/code" ]
  [ ! -e "$OUT/notes" ]
}

# ---------------------------------------------------------------------------
# Project root resolution
# ---------------------------------------------------------------------------

@test "project root prefers CLAUDE_PROJECT_DIR and prints its canonical path" {
  ln -s "$PROJ" "$TEST_TMPDIR/proj-link"
  CLAUDE_PROJECT_DIR="$TEST_TMPDIR/proj-link" run shunt_cw_project_root
  assert_success
  assert_output "$PROJ"
}

@test "project root ignores a CLAUDE_PROJECT_DIR that is not a directory and uses git" {
  touch "$TEST_TMPDIR/not-a-dir"
  git() { echo "$PROJ"; }
  CLAUDE_PROJECT_DIR="$TEST_TMPDIR/not-a-dir" run shunt_cw_project_root
  assert_success
  assert_output "$PROJ"
}

@test "project root uses git rev-parse --show-toplevel when CLAUDE_PROJECT_DIR is unset" {
  git() {
    [ "$1 $2" = "rev-parse --show-toplevel" ] || return 99
    echo "$PROJ"
  }
  run shunt_cw_project_root
  assert_success
  assert_output "$PROJ"
}

@test "project root falls back to the current directory when git fails" {
  git() { return 128; }
  cd "$OUTSIDE"
  run shunt_cw_project_root
  assert_success
  assert_output "$OUTSIDE"
}

@test "project root falls back to the current directory when git prints nothing" {
  git() { return 0; }
  cd "$OUTSIDE"
  run shunt_cw_project_root
  assert_success
  assert_output "$OUTSIDE"
}

# ---------------------------------------------------------------------------
# Target validation: refusals
# ---------------------------------------------------------------------------

@test "check refuses a leading .. component" {
  assert_refused_target "../x.txt"
}

@test "check refuses a .. component in the middle" {
  assert_refused_target "a/../b.txt"
}

@test "check refuses a trailing .. component" {
  assert_refused_target "a/.."
}

@test "check refuses . components" {
  assert_refused_target "./a.txt"
  assert_refused_target "a/./b.txt"
  assert_refused_target "."
}

@test "check refuses empty components from a double slash" {
  assert_refused_target "a//b.txt"
  assert_refused_target "//a.txt"
}

@test "check refuses a trailing slash" {
  assert_refused_target "a/"
  assert_refused_target "a/b.txt/"
}

@test "check refuses an empty target" {
  assert_refused_target ""
}

@test "check refuses a lone slash" {
  assert_refused_target "/"
}

@test "check refuses a target containing a newline" {
  assert_refused_target $'a\nb.txt'
  assert_refused_target $'dir/x\n.txt'
}

@test "check refuses a target containing other control characters" {
  assert_refused_target $'a\tb.txt'
  assert_refused_target $'a\x1bb.txt'
  assert_refused_target $'a\x7fb.txt'
  assert_refused_target $'a\rb.txt'
}

@test "check refuses an absolute path outside the root" {
  assert_refused_target "$OUTSIDE/x.txt"
}

@test "check refuses the sibling-prefix trick" {
  mkdir "$TEST_TMPDIR/proj-evil"
  assert_refused_target "$TEST_TMPDIR/proj-evil/x.txt"
}

@test "check refuses an absolute target whose ancestor is a sibling with the root as prefix" {
  # $PROJ-evil does not exist, its nearest existing ancestor is the parent
  # of the root, which is outside the root.
  assert_refused_target "$PROJ-evil/deep/x.txt"
}

@test "check refuses the root itself as target" {
  assert_refused_target "$PROJ"
}

@test "check refuses when the root is the filesystem root" {
  run shunt_cw_check_target "/" "tmp/shunt-cw-test-never-created.txt"
  assert_failure
  assert_output --partial "refusing target"
  [ ! -e /tmp/shunt-cw-test-never-created.txt ]
}

@test "check refuses a symlink to an outside directory as the target directory" {
  ln -s "$OUTSIDE" "$PROJ/link"
  assert_refused_target "link/x.txt"
  assert_refused_target "link/new/dir/x.txt"
}

@test "check refuses a symlinked directory in the middle that resolves outside" {
  mkdir -p "$PROJ/a" "$OUTSIDE/deeper"
  ln -s "$OUTSIDE" "$PROJ/a/l"
  assert_refused_target "a/l/deeper/x.txt"
  assert_refused_target "a/l/nothere/x.txt"
}

@test "check refuses a symlink target that points outside" {
  touch "$OUTSIDE/f"
  ln -s "$OUTSIDE/f" "$PROJ/t.txt"
  assert_refused_target "t.txt"
}

@test "check refuses a dangling symlink as the target" {
  ln -s "$OUTSIDE/does-not-exist" "$PROJ/t.txt"
  assert_refused_target "t.txt"
}

@test "check refuses a dangling symlink in the middle of the path" {
  ln -s "$PROJ/does-not-exist" "$PROJ/dangling"
  assert_refused_target "dangling/x.txt"
}

@test "check refuses a symlink to an inside file as the target" {
  touch "$PROJ/real.txt"
  ln -s real.txt "$PROJ/alias.txt"
  assert_refused_target "alias.txt"
}

@test "check refuses an existing file" {
  echo keep >"$PROJ/exists.txt"
  assert_refused_target "exists.txt"
  [ "$(cat "$PROJ/exists.txt")" = "keep" ]
}

@test "check refuses an existing directory" {
  mkdir -p "$PROJ/somedir"
  assert_refused_target "somedir"
}

@test "check refuses a target below an existing regular file" {
  touch "$PROJ/afile"
  assert_refused_target "afile/x.txt"
}

@test "check refuses a hit on .git in a component that does not exist yet" {
  assert_refused_target ".git/x"
  assert_refused_target "newdir/.git/x"
  assert_refused_target "a/b/.git"
}

@test "check refuses a hit on .claude in a component that does not exist yet" {
  assert_refused_target "newdir/.claude/y"
  assert_refused_target ".claude/y"
}

@test "check refuses a hit on .github in a component that does not exist yet" {
  assert_refused_target ".github/workflows/z.yml"
}

@test "check refuses .env and .env.* as file names" {
  assert_refused_target ".env"
  assert_refused_target ".env.local"
  assert_refused_target "sub/.envrc"
  assert_refused_target "sub/.env.production"
}

@test "check refuses an .env* directory component" {
  assert_refused_target ".envdir/x.txt"
}

@test "check matches the denylist case-insensitively" {
  assert_refused_target ".GIT/x"
  assert_refused_target "a/.Claude/x"
  assert_refused_target ".GitHub/x"
  assert_refused_target "a/.ENV"
}

@test "check refuses denylisted components in an absolute path inside the root" {
  assert_refused_target "$PROJ/.git/x"
  assert_refused_target "$PROJ/sub/.env"
}

@test "check refuses an existing denylisted directory" {
  mkdir -p "$PROJ/.git" "$PROJ/.claude"
  assert_refused_target ".git/config-new"
  assert_refused_target ".claude/new.md"
}

@test "check refuses a symlink whose real location is under .git" {
  mkdir -p "$PROJ/.git/hooks"
  ln -s .git/hooks "$PROJ/innocent"
  assert_refused_target "innocent/pre-commit"
}

@test "check refuses a symlink component literally named .claude even when it points inside the root" {
  mkdir -p "$PROJ/docs"
  ln -s docs "$PROJ/.claude"
  assert_refused_target ".claude/x.md"
}

@test "check refuses when the ancestor path is not searchable" {
  [ "$(id -u)" -ne 0 ] || skip "root can search any directory"
  mkdir -p "$PROJ/locked"
  chmod 000 "$PROJ/locked"
  run shunt_cw_check_target "$PROJ" "locked/x.txt"
  chmod 755 "$PROJ/locked"
  assert_failure
}

# ---------------------------------------------------------------------------
# Target validation: accepted targets
# ---------------------------------------------------------------------------

@test "check accepts a new file directly in the root and prints its resolved path" {
  run shunt_cw_check_target "$PROJ" "x.txt"
  assert_success
  assert_output "$PROJ/x.txt"
}

@test "check accepts new nested directories and does not create them" {
  run shunt_cw_check_target "$PROJ" "a/b/c/x.txt"
  assert_success
  assert_output "$PROJ/a/b/c/x.txt"
  [ ! -e "$PROJ/a" ]
}

@test "check accepts a new file in an existing directory" {
  mkdir -p "$PROJ/src"
  run shunt_cw_check_target "$PROJ" "src/x_test.go"
  assert_success
  assert_output "$PROJ/src/x_test.go"
}

@test "check accepts an absolute path inside the root" {
  run shunt_cw_check_target "$PROJ" "$PROJ/src/x.txt"
  assert_success
  assert_output "$PROJ/src/x.txt"
}

@test "check accepts an absolute path that reaches the root through a symlink" {
  ln -s "$PROJ" "$TEST_TMPDIR/proj-link"
  run shunt_cw_check_target "$PROJ" "$TEST_TMPDIR/proj-link/src/x.txt"
  assert_success
  assert_output "$PROJ/src/x.txt"
}

@test "check accepts a symlinked directory that resolves inside the root" {
  mkdir -p "$PROJ/real"
  ln -s real "$PROJ/alias"
  run shunt_cw_check_target "$PROJ" "alias/x.txt"
  assert_success
  assert_output "$PROJ/real/x.txt"
}

@test "check accepts a root that is given as a symlink" {
  ln -s "$PROJ" "$TEST_TMPDIR/proj-link"
  run shunt_cw_check_target "$TEST_TMPDIR/proj-link" "x.txt"
  assert_success
  assert_output "$PROJ/x.txt"
}

@test "check does not treat lookalike names as denylisted" {
  run shunt_cw_check_target "$PROJ" "env.txt"
  assert_success
  run shunt_cw_check_target "$PROJ" "my.git/x.txt"
  assert_success
  run shunt_cw_check_target "$PROJ" "docs/.github-notes.md"
  assert_success
  run shunt_cw_check_target "$PROJ" ".gitignore"
  assert_success
  run shunt_cw_check_target "$PROJ" "environment/x.txt"
  assert_success
}

@test "check accepts non-ASCII and space characters in names" {
  run shunt_cw_check_target "$PROJ" "dir with space/тест.txt"
  assert_success
  assert_output "$PROJ/dir with space/тест.txt"
}

@test "check accepts a name starting with a dash" {
  run shunt_cw_check_target "$PROJ" "-rf"
  assert_success
  assert_output "$PROJ/-rf"
}

# ---------------------------------------------------------------------------
# Response parser: unusable responses (exit 11)
# ---------------------------------------------------------------------------

@test "parse marks an empty response as unusable" {
  : >"$RESP"
  assert_parse_unusable "empty-response"
}

@test "parse marks a response without any delimiter as unusable" {
  printf 'just some prose\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a whitespace-only response as unusable" {
  printf '\n  \n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a missing NOTES delimiter as unusable" {
  printf '<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a missing CODE delimiter as unusable" {
  printf '<<<SHUNT-NOTES>>>\nnotes\n' >"$RESP"
  assert_parse_unusable "missing-code-delimiter"
}

@test "parse marks input truncated inside the CODE delimiter as unusable" {
  printf '<<<SHUNT-NOTES>>>\nnotes\n<<<SHUNT-COD' >"$RESP"
  assert_parse_unusable "missing-code-delimiter"
}

@test "parse marks a duplicated NOTES delimiter as unusable" {
  printf '<<<SHUNT-NOTES>>>\na\n<<<SHUNT-NOTES>>>\nb\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "duplicate-notes-delimiter"
}

@test "parse marks a duplicated CODE delimiter as unusable" {
  printf '<<<SHUNT-NOTES>>>\na\n<<<SHUNT-CODE>>>\ncode\n<<<SHUNT-CODE>>>\nmore\n' >"$RESP"
  assert_parse_unusable "duplicate-code-delimiter"
}

@test "parse marks delimiters in the wrong order as unusable" {
  printf '<<<SHUNT-CODE>>>\ncode\n<<<SHUNT-NOTES>>>\nnotes\n' >"$RESP"
  assert_parse_unusable "out-of-order"
}

@test "parse marks text before the first delimiter as unusable" {
  printf 'Sure, here you go:\n<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "text-before-delimiter"
}

@test "parse marks a delimiter with a trailing space as not a delimiter" {
  printf '<<<SHUNT-NOTES>>> \nn\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a delimiter with a leading space as not a delimiter" {
  printf ' <<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a delimiter followed by two carriage returns as not a delimiter" {
  printf '<<<SHUNT-NOTES>>>\r\r\nn\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks empty CODE without NOTES as unusable" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n' >"$RESP"
  assert_parse_unusable "empty-code"
}

@test "parse marks whitespace-only CODE and NOTES as unusable" {
  printf '<<<SHUNT-NOTES>>>\n  \n\n<<<SHUNT-CODE>>>\n \n\t\n' >"$RESP"
  assert_parse_unusable "empty-code"
}

@test "parse marks CODE that is only an empty fence and no NOTES as unusable" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n```go\n```\n' >"$RESP"
  assert_parse_unusable "empty-code"
}

@test "parse marks NUL bytes in CODE as unusable" {
  printf '<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\nab\000cd\n' >"$RESP"
  assert_parse_unusable "nul-bytes"
}

@test "parse marks NUL bytes in NOTES as unusable" {
  printf '<<<SHUNT-NOTES>>>\nn\000n\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "nul-bytes"
}

@test "parse marks invalid UTF-8 in CODE as unusable" {
  printf '<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\nab\377cd\n' >"$RESP"
  assert_parse_unusable "invalid-utf8"
}

@test "parse marks invalid UTF-8 in NOTES as unusable" {
  printf '<<<SHUNT-NOTES>>>\nn\303\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "invalid-utf8"
}

@test "parse rejects overlong, surrogate and out-of-range UTF-8 sequences" {
  local seq
  for seq in '\300\200' '\355\240\200' '\364\220\200\200' '\370\210\200\200\200'; do
    printf "<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\nx${seq}y\n" >"$RESP"
    assert_parse_unusable "invalid-utf8"
  done
}

@test "parse accepts valid multi-byte UTF-8 in CODE" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\ns := "h\303\251llo \342\202\254 \360\237\230\200"\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  assert_output "ok"
  printf 's := "h\303\251llo \342\202\254 \360\237\230\200"\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse marks CODE over the size cap as unusable" {
  export SHUNT_CW_MAX_CODE_BYTES=100
  { printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n'; head -c 100 /dev/zero | tr '\0' 'x'; printf '\n'; } >"$RESP"
  assert_parse_unusable "oversize"
}

@test "parse accepts CODE of exactly the size cap" {
  export SHUNT_CW_MAX_CODE_BYTES=100
  { printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n'; head -c 99 /dev/zero | tr '\0' 'x'; printf '\n'; } >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  [ "$(wc -c <"$OUT/code")" -eq 100 ]
}

@test "parse has a default size cap of about 256 KB" {
  { printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n'; head -c 262145 /dev/zero | tr '\0' 'x'; printf '\n'; } >"$RESP"
  assert_parse_unusable "oversize"
  { printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n'; head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n'; } >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse marks NOTES over its cap as unusable" {
  export SHUNT_CW_MAX_NOTES_BYTES=50
  { printf '<<<SHUNT-NOTES>>>\n'; head -c 60 /dev/zero | tr '\0' 'n'; printf '\n<<<SHUNT-CODE>>>\ncode\n'; } >"$RESP"
  assert_parse_unusable "oversize"
}

@test "parse rejects a response far larger than the caps before splitting it" {
  export SHUNT_CW_MAX_CODE_BYTES=100 SHUNT_CW_MAX_NOTES_BYTES=100
  head -c 20000 /dev/zero | tr '\0' 'x' >"$RESP"
  assert_parse_unusable "oversize"
}

@test "parse ignores a non-numeric size cap override and uses the default" {
  export SHUNT_CW_MAX_CODE_BYTES=banana
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse removes stale output files from an earlier call when the response is unusable" {
  echo stale >"$OUT/code"
  echo stale >"$OUT/notes"
  printf '<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

# ---------------------------------------------------------------------------
# Response parser: deliberate refusal (exit 10) and success (exit 0)
# ---------------------------------------------------------------------------

@test "parse reports empty CODE with NOTES as a deliberate refusal" {
  printf '<<<SHUNT-NOTES>>>\nCannot write the test: function foo is missing from the source.\n<<<SHUNT-CODE>>>\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
  printf 'Cannot write the test: function foo is missing from the source.\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/notes" "$TEST_TMPDIR/expected"
  [ ! -s "$OUT/code" ]
}

@test "parse reports whitespace-only CODE with NOTES as a deliberate refusal" {
  printf '<<<SHUNT-NOTES>>>\nnot enough context\n<<<SHUNT-CODE>>>\n\n  \n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
}

@test "parse reports an empty outer fence with NOTES as a deliberate refusal" {
  printf '<<<SHUNT-NOTES>>>\nnothing to do\n<<<SHUNT-CODE>>>\n```\n```\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
}

@test "parse splits a well-formed response into notes and code files" {
  cat >"$RESP" <<'EOF'
<<<SHUNT-NOTES>>>
skipped: nothing
<<<SHUNT-CODE>>>
package x

func A() {}
EOF
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  assert_output "ok"
  printf 'skipped: nothing\n' >"$TEST_TMPDIR/expected-notes"
  printf 'package x\n\nfunc A() {}\n' >"$TEST_TMPDIR/expected-code"
  cmp "$OUT/notes" "$TEST_TMPDIR/expected-notes"
  cmp "$OUT/code" "$TEST_TMPDIR/expected-code"
}

@test "parse accepts empty NOTES with non-empty CODE" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  [ ! -s "$OUT/notes" ]
  [ "$(cat "$OUT/code")" = "code" ]
}

@test "parse accepts whitespace-only text before the first delimiter" {
  printf '\n  \n\t\n<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse tolerates CRLF on the delimiter lines and keeps CR in the content" {
  printf '<<<SHUNT-NOTES>>>\r\nnote\r\n<<<SHUNT-CODE>>>\r\nline one\r\nline two\r\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'line one\r\nline two\r\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps delimiter-like text inside CODE that is not a whole-line match" {
  cat >"$RESP" <<'EOF'
<<<SHUNT-NOTES>>>
n
<<<SHUNT-CODE>>>
echo "<<<SHUNT-CODE>>>"
x <<<SHUNT-NOTES>>>
<<<SHUNT-NOTES>>> trailing
  <<<SHUNT-CODE>>>
<<<SHUNT-CODE>>>x
EOF
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  tail -n +4 "$RESP" >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps delimiter-like text inside NOTES that is not a whole-line match" {
  cat >"$RESP" <<'EOF'
<<<SHUNT-NOTES>>>
mention of <<<SHUNT-CODE>>> in prose
<<<SHUNT-CODE>>>
code
EOF
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'mention of <<<SHUNT-CODE>>> in prose\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/notes" "$TEST_TMPDIR/expected"
}

@test "parse adds a final newline when the last CODE line has none" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\nno newline at end' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'no newline at end\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse strips an outer fence with a language tag" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n```go\npackage x\n```\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'package x\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse strips an outer fence without a tag and with CRLF endings" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n```\r\ncode\r\n```\r\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'code\r\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse strips an outer fence padded with blank lines" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n\n```py\nx = 1\n```\n\n\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'x = 1\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps inner fence lines when stripping the outer fence" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n```md\n# Title\n```sh\nls\n```\ntext\n```\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '# Title\n```sh\nls\n```\ntext\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse honors a longer outer fence around inner three-backtick fences" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n````md\n```sh\nls\n```\n````\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '```sh\nls\n```\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps CODE untouched when the fence opens but never closes" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n```go\npackage x\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '```go\npackage x\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps CODE untouched when fence lines are only in the middle" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\nintro\n```\nx\n```\noutro\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'intro\n```\nx\n```\noutro\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse does not treat a closing line with trailing text as a fence" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n```go\nx\n``` trailing\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '```go\nx\n``` trailing\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse does not treat a shorter closing fence as closing a longer opening fence" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n````\nx\n```\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '````\nx\n```\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse fails with exit 2 for a missing response file" {
  run shunt_cw_parse "$TEST_TMPDIR/nope" "$OUT"
  assert_failure 2
}

@test "parse fails with exit 2 for a missing output directory" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$TEST_TMPDIR/no-such-dir"
  assert_failure 2
}

@test "parse fails with exit 2 when called with too few arguments" {
  run shunt_cw_parse "$RESP"
  assert_failure 2
}

# ---------------------------------------------------------------------------
# Publish: security and no-clobber behavior
# ---------------------------------------------------------------------------

@test "publish refuses an existing file and leaves it untouched" {
  echo keep >"$PROJ/exists.txt"
  local before
  before="$(snapshot)"
  run shunt_cw_publish "$PROJ" "exists.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "refusing target"
  [ "$(cat "$PROJ/exists.txt")" = "keep" ]
  [ "$before" = "$(snapshot)" ]
}

@test "publish refuses every invalid target without creating directories" {
  mkdir -p "$PROJ/real"
  ln -s "$OUTSIDE" "$PROJ/link"
  local before target
  before="$(snapshot)"
  for target in "newdir/../x" "newdir/.git/x" "newdir/.claude/y" "newdir/.env" \
    "link/newdir/x.txt" "newdir/" "" "$OUTSIDE/newdir/x.txt" "newdir//x"; do
    run shunt_cw_publish "$PROJ" "$target" "$CODE_IN"
    assert_failure
    [ "$before" = "$(snapshot)" ]
  done
}

@test "publish refuses invalid content before creating anything" {
  printf 'a\000b\n' >"$TEST_TMPDIR/nul"
  printf 'a\377b\n' >"$TEST_TMPDIR/bad-utf8"
  : >"$TEST_TMPDIR/empty"
  local before
  before="$(snapshot)"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/nul"
  assert_failure
  assert_output --partial "nul-bytes"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/bad-utf8"
  assert_failure
  assert_output --partial "invalid-utf8"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/empty"
  assert_failure
  SHUNT_CW_MAX_CODE_BYTES=3 run shunt_cw_publish "$PROJ" "newdir/x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "cap"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/missing-file"
  assert_failure 2
  [ "$before" = "$(snapshot)" ]
}

@test "publish never clobbers a file created between validation and publish" {
  _shunt_cw_seam() {
    [ "$1" = "before-link" ] || return 0
    echo racer >"$PROJ/a/x.txt"
  }
  mkdir -p "$PROJ/a"
  run shunt_cw_publish "$PROJ" "a/x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "nothing was overwritten"
  [ "$(cat "$PROJ/a/x.txt")" = "racer" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish never clobbers a symlink planted between validation and publish" {
  _shunt_cw_seam() {
    [ "$1" = "before-link" ] || return 0
    ln -s "$OUTSIDE/victim" "$PROJ/x.txt"
  }
  echo original >"$OUTSIDE/victim"
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "nothing was overwritten"
  [ "$(cat "$OUTSIDE/victim")" = "original" ]
  [ -L "$PROJ/x.txt" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish detects a racer on the mv fallback path even when mv -n exits 0" {
  ln() { return 1; }
  mv() {
    echo racer >"$PROJ/x.txt"
    command mv -n "$@"
    return 0
  }
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "nothing was overwritten"
  [ "$(cat "$PROJ/x.txt")" = "racer" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish falls back to mv -n when hard links are unavailable" {
  ln() { return 1; }
  run shunt_cw_publish "$PROJ" "sub/x.txt" "$CODE_IN"
  assert_success
  assert_output "$PROJ/sub/x.txt"
  cmp "$PROJ/sub/x.txt" "$CODE_IN"
  [ "$(mode_of "$PROJ/sub/x.txt")" = "644" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish re-checks the parent and refuses a swapped-in symlink to an outside directory" {
  _shunt_cw_seam() {
    [ "$1" = "after-mkdir" ] || return 0
    rmdir "$PROJ/a/b"
    ln -s "$OUTSIDE" "$PROJ/a/b"
  }
  run shunt_cw_publish "$PROJ" "a/b/x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "outside the project root"
  [ -z "$(find "$OUTSIDE" -type f)" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish re-checks the denylist on the final parent" {
  _shunt_cw_seam() {
    [ "$1" = "after-mkdir" ] || return 0
    rmdir "$PROJ/a/b"
    mkdir -p "$PROJ/.git"
    ln -s "../.git" "$PROJ/a/b"
  }
  run shunt_cw_publish "$PROJ" "a/b/x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "is not allowed"
  [ -z "$(find "$PROJ/.git" -type f)" ]
}

@test "publish refuses a parent swapped for a symlink to another directory inside the root" {
  mkdir -p "$PROJ/elsewhere"
  _shunt_cw_seam() {
    [ "$1" = "after-mkdir" ] || return 0
    rmdir "$PROJ/a/b"
    ln -s ../elsewhere "$PROJ/a/b"
  }
  run shunt_cw_publish "$PROJ" "a/b/x.txt" "$CODE_IN"
  assert_failure
  assert_output --partial "changed while publishing"
  [ -z "$(find "$PROJ/elsewhere" -type f)" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish does not report success when a directory is planted at the final name" {
  ln() {
    mkdir "$PROJ/x.txt"
    command ln "$@"
  }
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_failure
  [ -d "$PROJ/x.txt" ]
  [ -z "$(find "$PROJ/x.txt" -type f)" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish does not follow a symlink to a directory planted at the final name" {
  ln() {
    command ln -s "$OUTSIDE" "$PROJ/x.txt"
    command ln "$@"
  }
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_failure
  [ -z "$(find "$OUTSIDE" -type f)" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish does not report success when the mv fallback moves the file into a planted directory" {
  ln() { return 1; }
  mv() {
    mkdir "$PROJ/x.txt"
    command mv -n "$@"
  }
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_failure
  [ -z "$(find "$PROJ/x.txt" -type f)" ]
  [ -z "$(leftover_temp_files)" ]
}

# ---------------------------------------------------------------------------
# Publish: results, modes and rollback
# ---------------------------------------------------------------------------

@test "publish writes the code into a new file directly in the root" {
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_success
  assert_output "$PROJ/x.txt"
  cmp "$PROJ/x.txt" "$CODE_IN"
}

@test "publish creates only the missing directories with mode 755" {
  mkdir -p "$PROJ/a"
  chmod 700 "$PROJ/a"
  run shunt_cw_publish "$PROJ" "a/b/c/x.txt" "$CODE_IN"
  assert_success
  cmp "$PROJ/a/b/c/x.txt" "$CODE_IN"
  [ "$(mode_of "$PROJ/a")" = "700" ]
  [ "$(mode_of "$PROJ/a/b")" = "755" ]
  [ "$(mode_of "$PROJ/a/b/c")" = "755" ]
}

@test "publish gives the file mode 644 under umask 077" {
  umask 077
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  umask 022
  assert_success
  [ "$(mode_of "$PROJ/x.txt")" = "644" ]
}

@test "publish gives the file mode 644 under umask 000" {
  umask 000
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  umask 022
  assert_success
  [ "$(mode_of "$PROJ/x.txt")" = "644" ]
}

@test "publish never sets an exec bit even if the source file is executable" {
  chmod 755 "$CODE_IN"
  umask 000
  run shunt_cw_publish "$PROJ" "run.sh" "$CODE_IN"
  umask 022
  assert_success
  [ ! -x "$PROJ/run.sh" ]
  [ "$(mode_of "$PROJ/run.sh")" = "644" ]
}

@test "publish leaves a single link and no temp file behind on success" {
  run shunt_cw_publish "$PROJ" "sub/x.txt" "$CODE_IN"
  assert_success
  [ "$(link_count_of "$PROJ/sub/x.txt")" = "1" ]
  [ -z "$(leftover_temp_files)" ]
  [ "$(ls -A "$PROJ/sub")" = "x.txt" ]
}

@test "publish preserves content byte for byte including CRLF and non-ASCII" {
  printf 'line\r\n\303\251\342\202\254\n\n\ttab' >"$CODE_IN"
  run shunt_cw_publish "$PROJ" "x.txt" "$CODE_IN"
  assert_success
  cmp "$PROJ/x.txt" "$CODE_IN"
}

@test "publish accepts a root given as a symlink" {
  ln -s "$PROJ" "$TEST_TMPDIR/proj-link"
  run shunt_cw_publish "$TEST_TMPDIR/proj-link" "x.txt" "$CODE_IN"
  assert_success
  assert_output "$PROJ/x.txt"
}

@test "publish rollback removes only the directories this call created" {
  mkdir -p "$PROJ/a"
  ln() { return 1; }
  mv() { return 1; }
  run shunt_cw_publish "$PROJ" "a/b/c/x.txt" "$CODE_IN"
  assert_failure
  [ -d "$PROJ/a" ]
  [ ! -e "$PROJ/a/b" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish rollback keeps a created directory that another process filled" {
  _shunt_cw_seam() {
    [ "$1" = "before-link" ] || return 0
    echo other >"$PROJ/a/b/other.txt"
  }
  ln() { return 1; }
  mv() { return 1; }
  run shunt_cw_publish "$PROJ" "a/b/c/x.txt" "$CODE_IN"
  assert_failure
  [ "$(cat "$PROJ/a/b/other.txt")" = "other" ]
  [ ! -e "$PROJ/a/b/c" ]
  [ -z "$(leftover_temp_files)" ]
}

@test "publish rollback keeps a pre-existing directory that holds another file" {
  mkdir -p "$PROJ/a"
  echo other >"$PROJ/a/other.txt"
  ln() { return 1; }
  mv() { return 1; }
  run shunt_cw_publish "$PROJ" "a/b/x.txt" "$CODE_IN"
  assert_failure
  [ "$(cat "$PROJ/a/other.txt")" = "other" ]
  [ ! -e "$PROJ/a/b" ]
}

@test "publish rolls back created directories when the file name is too long" {
  local longname
  longname="$(head -c 300 /dev/zero | tr '\0' 'n')"
  run shunt_cw_publish "$PROJ" "newdir/$longname" "$CODE_IN"
  assert_failure
  [ ! -e "$PROJ/newdir" ]
  [ -z "$(leftover_temp_files)" ]
}

# ---------------------------------------------------------------------------
# Hardening found in review
# ---------------------------------------------------------------------------

@test "check refuses the denylist in a Turkish locale where I does not lower to i" {
  locale -a 2>/dev/null | grep -qi '^tr_.*utf-\?8$' || skip "no Turkish UTF-8 locale installed"
  local loc
  loc="$(locale -a | grep -i '^tr_.*utf-\?8$' | head -n 1)"
  LC_ALL="$loc" run shunt_cw_check_target "$PROJ" ".GITHUB/workflows/x.yml"
  assert_failure
  assert_output --partial "is not allowed"
  LC_ALL="$loc" run shunt_cw_check_target "$PROJ" ".GIT/x"
  assert_failure
}

@test "check refuses files that run code or steer the agent without a permission prompt" {
  local target
  for target in ".mcp.json" "CLAUDE.md" "sub/claude.local.md" ".gitmodules" ".gitattributes" \
    ".vscode/tasks.json" ".husky/pre-commit" ".devcontainer/devcontainer.json" \
    ".circleci/config.yml" ".gitlab-ci.yml"; do
    assert_refused_target "$target"
  done
}

@test "check refuses denylisted names with trailing dots or spaces" {
  assert_refused_target ".git./x"
  assert_refused_target ".git /x"
  assert_refused_target "a/.github.../x.yml"
  assert_refused_target ".env."
}

@test "check refuses the denylist through an absolute path that reaches the root via a symlink" {
  mkdir -p "$PROJ/docs"
  ln -s docs "$PROJ/.claude"
  ln -s "$PROJ" "$TEST_TMPDIR/proj-link"
  assert_refused_target "$TEST_TMPDIR/proj-link/.claude/x.md"
}

@test "check gives the same answer for an existing and a missing path outside the root" {
  touch "$OUTSIDE/exists.txt"
  run shunt_cw_check_target "$PROJ" "$OUTSIDE/exists.txt"
  assert_failure
  assert_output --partial "not a new path inside the project root"
  run shunt_cw_check_target "$PROJ" "$OUTSIDE/missing.txt"
  assert_failure
  assert_output --partial "outside the project root"
}

@test "check refuses a target longer than 4096 characters" {
  local long
  long="$(head -c 5000 /dev/zero | tr '\0' 'a')"
  assert_refused_target "$long"
  local before
  before="$(snapshot)"
  run shunt_cw_publish "$PROJ" "$long" "$CODE_IN"
  assert_failure
  [ "$before" = "$(snapshot)" ]
}

@test "check refuses a relative, empty or control-character root" {
  run shunt_cw_check_target "proj" "x.txt"
  assert_failure
  assert_output --partial "absolute"
  run shunt_cw_check_target "" "x.txt"
  assert_failure
  run shunt_cw_check_target "-" "x.txt"
  assert_failure
  local nl_root="$TEST_TMPDIR/root"$'\n'
  mkdir -p "$nl_root"
  run shunt_cw_check_target "$nl_root" "x.txt"
  assert_failure
  assert_output --partial "control characters"
}

@test "size cap overrides with leading zeros are read as decimal" {
  export SHUNT_CW_MAX_CODE_BYTES=0000000000000100
  { printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n'; head -c 99 /dev/zero | tr '\0' 'x'; printf '\n'; } >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  export SHUNT_CW_MAX_CODE_BYTES=08
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n0123456789\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 11
  assert_output "oversize"
}

@test "size cap overrides with more than 15 digits are ignored" {
  export SHUNT_CW_MAX_CODE_BYTES=99999999999999999999
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse marks raw control characters as unusable" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\nx = 1\033[2J\n' >"$RESP"
  assert_parse_unusable "control-characters"
  printf '<<<SHUNT-NOTES>>>\nhidden \033[8m text\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "control-characters"
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\na\177b\n' >"$RESP"
  assert_parse_unusable "control-characters"
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\na\vb\n' >"$RESP"
  assert_parse_unusable "control-characters"
}

@test "parse still accepts tab, form feed and CRLF in CODE" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\n\tindented\r\n\f\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse marks Unicode bidi override and isolate characters as unusable" {
  local seq
  for seq in '\342\200\252' '\342\200\256' '\342\201\246' '\342\201\251'; do
    printf "<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\nx = \"a${seq}b\"\n" >"$RESP"
    assert_parse_unusable "bidi-controls"
  done
}

@test "parse accepts other invisible-adjacent characters that are not bidi overrides" {
  printf '<<<SHUNT-NOTES>>>\n<<<SHUNT-CODE>>>\nx = "a\342\200\213b \342\200\216"\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "publish refuses control characters and bidi controls in the content" {
  local before
  printf 'x\033[2J\n' >"$TEST_TMPDIR/ctl"
  printf 'x = "a\342\200\256b"\n' >"$TEST_TMPDIR/bidi"
  before="$(snapshot)"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/ctl"
  assert_failure
  assert_output --partial "control-characters"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/bidi"
  assert_failure
  assert_output --partial "bidi-controls"
  [ "$before" = "$(snapshot)" ]
}

@test "publish refuses an over-long target without creating directories" {
  local before
  before="$(snapshot)"
  run shunt_cw_publish "$PROJ" "a/$(head -c 300 /dev/zero | tr '\0' 'x')/$(head -c 300 /dev/zero | tr '\0' 'y')" "$CODE_IN"
  assert_failure
  [ "$before" = "$(snapshot)" ]
}

@test "cleanup after an interrupted publish removes the temp file and own directories" {
  mkdir -p "$PROJ/a"
  _shunt_cw_seam() {
    [ "$1" = "before-link" ] || return 0
    touch "$TEST_TMPDIR/ready"
    sleep 30 &
    wait $!
  }
  (
    trap 'shunt_cw_cleanup; exit 143' TERM
    shunt_cw_publish "$PROJ" "a/b/c/x.txt" "$CODE_IN" >/dev/null 2>&1
  ) &
  local pid=$! tries=0
  while [ ! -e "$TEST_TMPDIR/ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -e "$TEST_TMPDIR/ready" ]
  kill -TERM "$pid"
  wait "$pid" || true
  [ -z "$(leftover_temp_files)" ]
  [ ! -e "$PROJ/a/b" ]
  [ -d "$PROJ/a" ]
}

@test "cleanup does nothing after a completed publish" {
  run shunt_cw_publish "$PROJ" "sub/x.txt" "$CODE_IN"
  assert_success
  shunt_cw_publish "$PROJ" "sub/x.txt" "$CODE_IN" >/dev/null 2>&1 || true
  shunt_cw_cleanup
  [ -d "$PROJ/sub" ]
  cmp "$PROJ/sub/x.txt" "$CODE_IN"
}

@test "publish still cleans up the temp file and own directories under set -e" {
  mkdir -p "$PROJ/a"
  run bash -c '
    set -euo pipefail
    source "$1/scripts/lib/codewrite.sh"
    ln() { return 1; }
    mv() { return 1; }
    shunt_cw_publish "$2" "a/b/c/x.txt" "$3" 2>&1
  ' _ "$REPO_ROOT" "$PROJ" "$CODE_IN"
  assert_failure
  assert_output --partial "nothing was overwritten"
  [ ! -e "$PROJ/a/b" ]
  [ -d "$PROJ/a" ]
  [ -z "$(leftover_temp_files)" ]
}
