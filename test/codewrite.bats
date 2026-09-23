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

# resp_of <notes> <code>: writes a well-formed reply (all four tags, each on
# a line of its own) to $RESP. Both arguments are printf formats for the exact
# text of the section, including its final line feed. An empty argument makes
# an empty section.
resp_of() {
  {
    printf '<SHUNT-NOTES>\n'
    printf "$1"
    printf '</SHUNT-NOTES>\n<SHUNT-CODE>\n'
    printf "$2"
    printf '</SHUNT-CODE>\n'
  } >"$RESP"
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
  assert_refused_target ".GITHUB/workflows/x.yml"
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

@test "check does not treat lookalike names as refused" {
  run shunt_cw_check_target "$PROJ" "env.txt"
  assert_success
  run shunt_cw_check_target "$PROJ" "my.git/x.txt"
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

@test "parse marks a response without any tag as unusable" {
  printf 'just some prose\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a whitespace-only response as unusable" {
  printf '\n  \n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a missing NOTES tag as unusable" {
  printf '<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks a missing CODE tag as unusable" {
  printf '<SHUNT-NOTES>\nnotes\n</SHUNT-NOTES>\n' >"$RESP"
  assert_parse_unusable "missing-code-delimiter"
}

@test "parse marks input truncated inside the CODE tag as unusable" {
  printf '<SHUNT-NOTES>\nnotes\n</SHUNT-NOTES>\n<SHUNT-COD' >"$RESP"
  assert_parse_unusable "missing-code-delimiter"
}

@test "parse marks a reply cut off before the closing CODE tag as unusable" {
  printf '<SHUNT-NOTES>\nnotes\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\nmore code\n' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
}

@test "parse marks a reply cut off inside the closing CODE tag as unusable" {
  printf '<SHUNT-NOTES>\nnotes\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-COD' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
}

@test "parse marks a missing closing NOTES tag as unusable" {
  printf '<SHUNT-NOTES>\nnotes\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
}

@test "parse marks a closing tag before its opening tag as unusable" {
  printf '</SHUNT-NOTES>\n<SHUNT-NOTES>\nnotes\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "out-of-order"
  printf '<SHUNT-NOTES>\nnotes\n</SHUNT-NOTES>\n</SHUNT-CODE>\n<SHUNT-CODE>\ncode\n' >"$RESP"
  assert_parse_unusable "out-of-order"
}

@test "parse marks a duplicated NOTES tag as unusable" {
  printf '<SHUNT-NOTES>\na\n<SHUNT-NOTES>\nb\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "duplicate-notes-delimiter"
}

@test "parse marks a duplicated CODE tag as unusable" {
  printf '<SHUNT-NOTES>\na\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n<SHUNT-CODE>\nmore\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "duplicate-code-delimiter"
}

@test "parse marks a duplicated closing CODE tag as unusable" {
  printf '<SHUNT-NOTES>\na\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "duplicate-closing-tag"
}

@test "parse marks a duplicated closing NOTES tag as unusable" {
  printf '<SHUNT-NOTES>\na\n</SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "duplicate-closing-tag"
}

@test "parse marks tags in the wrong order as unusable" {
  printf '<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n<SHUNT-NOTES>\nnotes\n</SHUNT-NOTES>\n' >"$RESP"
  assert_parse_unusable "out-of-order"
}

@test "parse marks text before the first tag as unusable" {
  printf 'Sure, here you go:\n<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "text-before-delimiter"
}

@test "parse marks text between the notes and the code sections as unusable" {
  printf '<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\nHere is the file:\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "text-between-sections"
}

@test "parse marks text after the closing CODE tag as unusable" {
  printf '<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\nHope that helps.\n' >"$RESP"
  assert_parse_unusable "text-after-closing-tag"
}

@test "parse accepts only blank lines before, between and after the sections" {
  printf '\n \t\n<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n\n  \n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n\n \n\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  assert_output "ok"
  [ "$(cat "$OUT/code")" = "code" ]
}

@test "parse marks a reply in the old open-delimiter form as unusable" {
  printf '<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\ncode\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
  printf '<<<SHUNT-NOTES>>>\nn\n<<<SHUNT-CODE>>>\ncode\n</SHUNT-CODE>>>\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse does not accept a mangled closing line as the closing tag" {
  printf '<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\nx := 1\n</SHUNT-CODE>>>' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
  printf '<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\nx := 1\n</SHUNT-CODE>>>\n' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
}

@test "parse marks a tag with a trailing space as not a tag" {
  printf '<SHUNT-NOTES> \nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
  printf '<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE> \n' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
}

@test "parse marks a tag with a leading space as not a tag" {
  printf ' <SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
  printf '<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n </SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-closing-tag"
}

@test "parse marks a tag followed by two carriage returns as not a tag" {
  printf '<SHUNT-NOTES>\r\r\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

@test "parse marks empty CODE without NOTES as unusable" {
  resp_of '' ''
  assert_parse_unusable "empty-code"
}

@test "parse marks whitespace-only CODE and NOTES as unusable" {
  resp_of '  \n\n' ' \n\t\n'
  assert_parse_unusable "empty-code"
}

@test "parse marks CODE that is only an empty fence and no NOTES as unusable" {
  resp_of '' '```go\n```\n'
  assert_parse_unusable "empty-code"
}

@test "parse marks NUL bytes in CODE as unusable" {
  resp_of 'n\n' 'ab\000cd\n'
  assert_parse_unusable "nul-bytes"
}

@test "parse marks NUL bytes in NOTES as unusable" {
  resp_of 'n\000n\n' 'code\n'
  assert_parse_unusable "nul-bytes"
}

@test "parse marks invalid UTF-8 in CODE as unusable" {
  resp_of 'n\n' 'ab\377cd\n'
  assert_parse_unusable "invalid-utf8"
}

@test "parse marks invalid UTF-8 in NOTES as unusable" {
  resp_of 'n\303\n' 'code\n'
  assert_parse_unusable "invalid-utf8"
}

@test "parse rejects overlong, surrogate and out-of-range UTF-8 sequences" {
  local seq
  for seq in '\300\200' '\355\240\200' '\364\220\200\200' '\370\210\200\200\200'; do
    resp_of "n\n" "x${seq}y\n"
    assert_parse_unusable "invalid-utf8"
  done
}

@test "parse accepts valid multi-byte UTF-8 in CODE" {
  resp_of '' 's := "h\303\251llo \342\202\254 \360\237\230\200"\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  assert_output "ok"
  printf 's := "h\303\251llo \342\202\254 \360\237\230\200"\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse marks CODE over the size cap as unusable" {
  export SHUNT_CW_MAX_CODE_BYTES=100
  { printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\n'; head -c 100 /dev/zero | tr '\0' 'x'; printf '\n</SHUNT-CODE>\n'; } >"$RESP"
  assert_parse_unusable "oversize"
}

@test "parse accepts CODE of exactly the size cap" {
  export SHUNT_CW_MAX_CODE_BYTES=100
  { printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\n'; head -c 99 /dev/zero | tr '\0' 'x'; printf '\n</SHUNT-CODE>\n'; } >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  [ "$(wc -c <"$OUT/code")" -eq 100 ]
}

@test "parse has a default size cap of about 256 KB" {
  { printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\n'; head -c 262145 /dev/zero | tr '\0' 'x'; printf '\n</SHUNT-CODE>\n'; } >"$RESP"
  assert_parse_unusable "oversize"
  { printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\n'; head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n</SHUNT-CODE>\n'; } >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse marks NOTES over its cap as unusable" {
  export SHUNT_CW_MAX_NOTES_BYTES=50
  { printf '<SHUNT-NOTES>\n'; head -c 60 /dev/zero | tr '\0' 'n'; printf '\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n'; } >"$RESP"
  assert_parse_unusable "oversize"
}

@test "parse rejects a response far larger than the caps before splitting it" {
  export SHUNT_CW_MAX_CODE_BYTES=100 SHUNT_CW_MAX_NOTES_BYTES=100
  head -c 20000 /dev/zero | tr '\0' 'x' >"$RESP"
  assert_parse_unusable "oversize"
}

@test "parse ignores a non-numeric size cap override and uses the default" {
  export SHUNT_CW_MAX_CODE_BYTES=banana
  resp_of '' 'code\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse removes stale output files from an earlier call when the response is unusable" {
  echo stale >"$OUT/code"
  echo stale >"$OUT/notes"
  printf '<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  assert_parse_unusable "missing-notes-delimiter"
}

# ---------------------------------------------------------------------------
# Response parser: deliberate refusal (exit 10) and success (exit 0)
# ---------------------------------------------------------------------------

@test "parse reports empty CODE with NOTES as a deliberate refusal" {
  resp_of 'Cannot write the test: function foo is missing from the source.\n' ''
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
  printf 'Cannot write the test: function foo is missing from the source.\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/notes" "$TEST_TMPDIR/expected"
  [ ! -s "$OUT/code" ]
}

@test "parse reports whitespace-only CODE with NOTES as a deliberate refusal" {
  resp_of 'not enough context\n' '\n  \n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
}

@test "parse reports an empty outer fence with NOTES as a deliberate refusal" {
  resp_of 'nothing to do\n' '```\n```\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
}

@test "parse splits a well-formed response into notes and code files" {
  cat >"$RESP" <<'EOF'
<SHUNT-NOTES>
skipped: nothing
</SHUNT-NOTES>
<SHUNT-CODE>
package x

func A() {}
</SHUNT-CODE>
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
  resp_of '' 'code\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  [ ! -s "$OUT/notes" ]
  [ "$(cat "$OUT/code")" = "code" ]
}

@test "parse accepts whitespace-only text before the first tag" {
  printf '\n  \n\t\n<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\ncode\n</SHUNT-CODE>\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse tolerates CRLF on the tag lines and keeps CR in the content" {
  printf '<SHUNT-NOTES>\r\nnote\r\n</SHUNT-NOTES>\r\n<SHUNT-CODE>\r\nline one\r\nline two\r\n</SHUNT-CODE>\r\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'line one\r\nline two\r\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps tag-like text inside CODE that is not a whole-line match" {
  cat >"$RESP" <<'EOF'
<SHUNT-NOTES>
n
</SHUNT-NOTES>
<SHUNT-CODE>
echo "<SHUNT-CODE>"
x <SHUNT-NOTES>
<SHUNT-NOTES> trailing
  a </SHUNT-CODE> y
</SHUNT-CODE>x
</SHUNT-CODE>
EOF
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  sed -n '5,9p' "$RESP" >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps tag-like text inside NOTES that is not a whole-line match" {
  cat >"$RESP" <<'EOF'
<SHUNT-NOTES>
mention of <SHUNT-CODE> in prose
</SHUNT-NOTES>
<SHUNT-CODE>
code
</SHUNT-CODE>
EOF
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'mention of <SHUNT-CODE> in prose\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/notes" "$TEST_TMPDIR/expected"
}

@test "parse ends the CODE with one line feed when the response has no final newline" {
  printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\nlast line\n</SHUNT-CODE>' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'last line\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps blank lines just inside the CODE tags" {
  resp_of '' '\nx = 1\n\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '\nx = 1\n\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse still reports a deliberate refusal when the CODE section is empty" {
  printf '<SHUNT-NOTES>\nno context\n</SHUNT-NOTES>\n<SHUNT-CODE>\n</SHUNT-CODE>\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 10
  assert_output "deliberate-refusal"
  [ "$(cat "$OUT/notes")" = "no context" ]
}

@test "parse strips an outer fence with a language tag" {
  resp_of '' '```go\npackage x\n```\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'package x\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse strips an outer fence without a tag and with CRLF endings" {
  resp_of '' '```\r\ncode\r\n```\r\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'code\r\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse strips an outer fence padded with blank lines" {
  resp_of '' '\n```py\nx = 1\n```\n\n\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'x = 1\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps inner fence lines when stripping the outer fence" {
  resp_of '' '```md\n# Title\n```sh\nls\n```\ntext\n```\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '# Title\n```sh\nls\n```\ntext\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse honors a longer outer fence around inner three-backtick fences" {
  resp_of '' '````md\n```sh\nls\n```\n````\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '```sh\nls\n```\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps CODE untouched when the fence opens but never closes" {
  resp_of '' '```go\npackage x\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '```go\npackage x\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse keeps CODE untouched when fence lines are only in the middle" {
  resp_of '' 'intro\n```\nx\n```\noutro\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'intro\n```\nx\n```\noutro\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse does not treat a closing line with trailing text as a fence" {
  resp_of '' '```go\nx\n``` trailing\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf '```go\nx\n``` trailing\n' >"$TEST_TMPDIR/expected"
  cmp "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse does not treat a shorter closing fence as closing a longer opening fence" {
  resp_of '' '````\nx\n```\n'
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
  resp_of '' 'code\n'
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
  { printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\n'; head -c 99 /dev/zero | tr '\0' 'x'; printf '\n</SHUNT-CODE>\n'; } >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  export SHUNT_CW_MAX_CODE_BYTES=08
  resp_of '' '0123456789\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_failure 11
  assert_output "oversize"
}

@test "size cap overrides with more than 15 digits are ignored" {
  export SHUNT_CW_MAX_CODE_BYTES=99999999999999999999
  resp_of '' 'code\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse marks raw control characters as unusable" {
  resp_of '' 'x = 1\033[2J\n'
  assert_parse_unusable "control-characters"
  resp_of 'hidden \033[8m text\n' 'code\n'
  assert_parse_unusable "control-characters"
  resp_of '' 'a\177b\n'
  assert_parse_unusable "control-characters"
  resp_of '' 'a\vb\n'
  assert_parse_unusable "control-characters"
}

@test "parse still accepts tab and CRLF in CODE" {
  resp_of '' '\tindented\r\n\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "parse marks a lone carriage return in CODE as unusable" {
  resp_of '' 'x=1\rEVIL\n'
  assert_parse_unusable "control-characters"
  resp_of '' 'x=1\r\rEVIL\r\n'
  assert_parse_unusable "control-characters"
}

@test "parse accepts a closing tag that ends the response with a bare carriage return" {
  printf '<SHUNT-NOTES>\n</SHUNT-NOTES>\n<SHUNT-CODE>\nx=1\n</SHUNT-CODE>\r' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  [ "$(cat "$OUT/code")" = "x=1" ]
}

@test "parse marks a form feed in CODE as unusable" {
  resp_of '' 'x=1\fEVIL\n'
  assert_parse_unusable "control-characters"
  resp_of '' '\f\nx=1\n'
  assert_parse_unusable "control-characters"
}

@test "parse accepts CRLF on every line of CODE and keeps the bytes" {
  printf '<SHUNT-NOTES>\r\nn\r\n</SHUNT-NOTES>\r\n<SHUNT-CODE>\r\na=1\r\n\r\nb=2\r\n</SHUNT-CODE>\r\n' >"$RESP"
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  printf 'a=1\r\n\r\nb=2\r\n' >"$TEST_TMPDIR/expected"
  cmp -s "$OUT/code" "$TEST_TMPDIR/expected"
}

@test "parse marks mixed CRLF plus one lone carriage return in CODE as unusable" {
  resp_of '' 'a=1\r\nb=2\rEVIL\r\nc=3\r\n'
  assert_parse_unusable "control-characters"
}

@test "parse still accepts a carriage return and a form feed in NOTES" {
  resp_of 'note\rone\f\n' 'x=1\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "publish refuses a lone carriage return or a form feed in the content" {
  local before content
  : >"$TEST_TMPDIR/ctl"
  before="$(snapshot)"
  for content in 'x=1\rEVIL\n' 'x=1\r' 'x=1\fy\n' 'a\r\nb\rc\r\n'; do
    printf "$content" >"$TEST_TMPDIR/ctl"
    run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/ctl"
    assert_failure
    assert_output --partial "control-characters"
  done
  [ "$before" = "$(snapshot)" ]
  printf 'a\r\nb\r\n' >"$TEST_TMPDIR/ctl"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/ctl"
  assert_success
}

@test "parse marks Unicode bidi override and isolate characters as unusable" {
  local seq
  for seq in '\342\200\252' '\342\200\256' '\342\201\246' '\342\201\251'; do
    resp_of "" "x = \"a${seq}b\"\n"
    assert_parse_unusable "bidi-controls"
  done
}

@test "parse marks zero width and other invisible characters in CODE as unusable" {
  resp_of '' 'x = "a\342\200\213b \342\200\216"\n'
  assert_parse_unusable "invisible-characters"
}

@test "parse marks a stray protocol tag line in CODE as unusable" {
  # The live failure: correct tags plus a stray mangled closing tag at the end.
  resp_of 'n\n' 'x = 1\n</SHUNT-CODE>>\n'
  assert_parse_unusable "protocol-tag-in-code"
  resp_of 'n\n' 'x = 1\n</SHUNT-CODE>>>\n'
  assert_parse_unusable "protocol-tag-in-code"
  resp_of 'n\n' 'x = 1\n<<</shunt-notes>>>\ny = 2\n'
  assert_parse_unusable "protocol-tag-in-code"
  resp_of 'n\n' 'x = 1\n</shunt-notes>>\ny = 2\n'
  assert_parse_unusable "protocol-tag-in-code"
  resp_of 'n\n' 'x = 1\n \t <SHUNT-CODE>  \r\ny = 2\n'
  assert_parse_unusable "protocol-tag-in-code"
  resp_of 'n\n' 'x = 1\nShunt-Notes\n'
  assert_parse_unusable "protocol-tag-in-code"
}

@test "parse marks a whole-line protocol tag inside CODE as unusable" {
  # An exact tag line splits the reply, so it is caught as a duplicate or a
  # misplaced tag before the look-alike check gets to see the code.
  resp_of 'n\n' 'x = 1\n<SHUNT-CODE>\ny = 2\n'
  assert_parse_unusable "duplicate-code-delimiter"
  resp_of 'n\n' 'x = 1\n</SHUNT-NOTES>\ny = 2\n'
  assert_parse_unusable "duplicate-closing-tag"
  resp_of 'n\n' 'x = 1\n<SHUNT-NOTES>\ny = 2\n'
  assert_parse_unusable "duplicate-notes-delimiter"
}

@test "parse accepts CODE that only mentions a protocol tag inside a line" {
  resp_of 'n\n' 'x = "<SHUNT-CODE>"\n# see SHUNT-CODE above\ny = 2 # </SHUNT-NOTES>\n<<<<SHUNT-CODE>>>>\n<SHUNT-CODEX>\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  assert_output "ok"
  grep -qxF 'x = "<SHUNT-CODE>"' "$OUT/code"
  grep -qxF '# see SHUNT-CODE above' "$OUT/code"
}

@test "parse still accepts a normal response after the protocol tag check" {
  resp_of 'note\n' 'x = 1\ny = 2\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  assert_output "ok"
}

@test "parse accepts a protocol tag look-alike in NOTES" {
  resp_of '</SHUNT-CODE>>\n' 'x = 1\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
}

@test "publish refuses a protocol tag line in the content and accepts a mention" {
  local before line
  : >"$TEST_TMPDIR/tag"
  before="$(snapshot)"
  for line in '</SHUNT-CODE>>' '<<</shunt-notes>>>' '  <SHUNT-CODE>  ' \
      '<SHUNT-CODE>' '</SHUNT-CODE>' '<SHUNT-NOTES>' '</SHUNT-NOTES>' $'</shunt-notes>\t'; do
    printf 'x = 1\n%s\ny = 2\n' "$line" >"$TEST_TMPDIR/tag"
    run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/tag"
    assert_failure
    assert_output --partial "protocol-tag-in-code"
  done
  [ "$before" = "$(snapshot)" ]
  printf 'x = "<SHUNT-CODE>"\n# see SHUNT-CODE above\n' >"$TEST_TMPDIR/tag"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/tag"
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

# --- lexical path normalization ---------------------------------------------

@test "normalize drops dot and empty segments and collapses a/.." {
  run shunt_cw_normalize_path /r/./x
  assert_output "/r/x"
  run shunt_cw_normalize_path /r/a/./b
  assert_output "/r/a/b"
  run shunt_cw_normalize_path /r/a//b
  assert_output "/r/a/b"
  run shunt_cw_normalize_path /r/a/../b
  assert_output "/r/b"
  run shunt_cw_normalize_path /r/a/b/../../c
  assert_output "/r/c"
}

@test "normalize lets an absolute path climb no higher than /" {
  run shunt_cw_normalize_path /../x
  assert_output "/x"
  run shunt_cw_normalize_path /a/../../x
  assert_output "/x"
  run shunt_cw_normalize_path /a/..
  assert_output "/"
}

@test "normalize keeps leading .. of a relative path and prints . for an empty result" {
  run shunt_cw_normalize_path ../x
  assert_output "../x"
  run shunt_cw_normalize_path a/../../x
  assert_output "../x"
  run shunt_cw_normalize_path ../../x
  assert_output "../../x"
  run shunt_cw_normalize_path ./x
  assert_output "x"
  run shunt_cw_normalize_path a/..
  assert_output "."
}

@test "normalize does not treat names that only contain dots as dot segments" {
  run shunt_cw_normalize_path /r/..a/b../.c/...
  assert_output "/r/..a/b../.c/..."
}

@test "normalize leaves an empty path, a trailing slash and control characters for the check to refuse" {
  run shunt_cw_normalize_path ""
  assert_output ""
  run shunt_cw_normalize_path /r/a/
  assert_output "/r/a/"
  run shunt_cw_normalize_path $'/r/a\nb/../c'
  assert_output $'/r/a\nb/../c'
}

@test "check accepts a normalized spelling of a dotted target and still refuses one that escapes" {
  local norm
  norm=$(shunt_cw_normalize_path "$PROJ/./tests//sub/../x_test.go")
  run shunt_cw_check_target "$PROJ" "$norm"
  assert_success
  assert_output "$PROJ/tests/x_test.go"
  norm=$(shunt_cw_normalize_path "$PROJ/../x")
  run shunt_cw_check_target "$PROJ" "$norm"
  assert_failure
}

# ---------------------------------------------------------------------------
# Security review round: root fallback, denylist additions, Unicode
# ---------------------------------------------------------------------------

# test_locales: C, and C.UTF-8 when the platform provides it. The Unicode
# checks must give the same answer in both.
test_locales() {
  echo C
  if ! command -v locale >/dev/null 2>&1 || locale -a 2>/dev/null | grep -qi '^c\.utf'; then
    echo C.UTF-8
  fi
}

# in_locale <locale> <command...>: runs a library function in a fresh shell
# with LC_ALL set, the way a user with that locale would hit it.
in_locale() {
  local loc="$1"
  shift
  run env LC_ALL="$loc" bash -c 'source "$1"; shift; "$@"' _ "$REPO_ROOT/scripts/lib/codewrite.sh" "$@"
}

# The invisible characters as printf escapes: C1 controls, the soft hyphen,
# zero width and format characters, line and paragraph separators, bidi
# overrides and isolates, the BOM, the Arabic letter mark, filler characters
# (Hangul, Khmer, Braille blank), variation selectors, the interlinear
# annotation marks, the musical formatting characters and the ends and middle
# of the Tag block and of the variation selectors supplement.
INVISIBLE_SEQS=(
  '\302\200' '\302\205' '\302\237' '\302\255'
  '\315\217' '\330\234'
  '\341\205\237' '\341\205\240' '\341\236\264' '\341\236\265' '\341\240\216'
  '\342\200\213' '\342\200\214' '\342\200\215' '\342\200\216' '\342\200\217'
  '\342\200\250' '\342\200\251' '\342\200\252' '\342\200\253' '\342\200\254' '\342\200\255' '\342\200\256'
  '\342\201\240' '\342\201\241' '\342\201\242' '\342\201\243' '\342\201\244' '\342\201\245'
  '\342\201\246' '\342\201\247' '\342\201\250' '\342\201\251'
  '\342\201\252' '\342\201\253' '\342\201\254' '\342\201\255' '\342\201\256' '\342\201\257'
  '\342\240\200' '\343\205\244'
  '\357\270\200' '\357\270\207' '\357\270\217'
  '\357\273\277' '\357\276\240'
  '\357\277\271' '\357\277\272' '\357\277\273'
  '\360\235\205\263' '\360\235\205\266' '\360\235\205\272'
  '\363\240\200\200' '\363\240\201\201' '\363\240\201\277'
  '\363\240\204\200' '\363\240\206\200' '\363\240\207\257'
)

# The characters a code file may keep although shunt_cw_strip_invisible
# removes them: the zero width non-joiner and joiner and variation selector 16
# (emoji sequences).
CODE_ALLOWED_SEQS=('\342\200\214' '\342\200\215' '\357\270\217')

# Characters next to the ranges above that must stay untouched: NBSP, e-acute,
# CJK, an emoji, hair space, U+E0080, U+FEFE and the neighbours of the ranges
# (U+00AC, U+00AE, U+034E, U+061B, U+115E, U+1161, U+17B3, U+17B6, U+180D,
# U+180F, U+2027, U+202F, U+2070, U+27FF, U+2801, U+3163, U+3165, U+FF9F,
# U+FFA1, U+FE10, U+FFF8, U+FFFC, U+1D172, U+1D17B, U+E00FF, U+E01F0).
PLAIN_UNICODE_SEQS=(
  '\302\240' '\303\251' '\344\270\255' '\360\237\230\200' '\342\200\212' '\363\240\202\200' '\357\273\276'
  '\302\254' '\302\256' '\315\216' '\330\233' '\341\205\236' '\341\205\241' '\341\236\263' '\341\236\266'
  '\341\240\215' '\341\240\217' '\342\200\247' '\342\200\257' '\342\201\260' '\342\237\277' '\342\240\201'
  '\343\205\243' '\343\205\245' '\357\276\237' '\357\276\241' '\357\270\220' '\357\277\270' '\357\277\274'
  '\360\235\205\262' '\360\235\205\273' '\363\240\203\277' '\363\240\207\260'
)

# code_refused_seqs: the invisible sequences that make CODE unusable under the
# reason "invisible-characters". C1 controls and bidi controls have their own
# reasons, and the code-allowed ones are the exception.
code_refused_seqs() {
  local seq
  for seq in "${INVISIBLE_SEQS[@]}"; do
    case "$seq" in
      '\302\200'|'\302\205'|'\302\237') ;;
      '\342\200\214'|'\342\200\215'|'\357\270\217') ;;
      '\342\200\25'[2-6]|'\342\201\246'|'\342\201\247'|'\342\201\250'|'\342\201\251') ;;
      *) printf '%s\n' "$seq" ;;
    esac
  done
}

@test "project root refuses a cwd fallback below a root-list or sensitive component" {
  git() { return 128; }
  local bad root
  for bad in .git/hooks .claude/agents .ssh .gnupg .aws .kube .config/gcloud .local/share .docker .azure \
      .github/workflows .SSH .Git. ".claude "; do
    root="$TEST_TMPDIR/fake-home/$bad"
    mkdir -p "$root"
    cd "$root"
    run shunt_cw_project_root
    assert_failure
    assert_output --partial "git work tree"
    assert_output --partial "CLAUDE_PROJECT_DIR"
  done
}

@test "project root refuses a cwd fallback whose ancestor is on the root list, not only its last component" {
  git() { return 128; }
  mkdir -p "$TEST_TMPDIR/fake-home/.ssh/deep/er"
  cd "$TEST_TMPDIR/fake-home/.ssh/deep/er"
  run shunt_cw_project_root
  assert_failure
  assert_output --partial "'.ssh'"
}

@test "project root accepts an ordinary cwd fallback" {
  git() { return 128; }
  mkdir -p "$TEST_TMPDIR/work/my-project"
  cd "$TEST_TMPDIR/work/my-project"
  run shunt_cw_project_root
  assert_success
  assert_output "$(cd -P "$TEST_TMPDIR/work/my-project" && pwd -P)"
}

@test "project root keeps a git worktree below .claude/worktrees working" {
  local wt="$TEST_TMPDIR/repo/.claude/worktrees/feature"
  mkdir -p "$wt/src"
  wt="$(cd -P "$wt" && pwd -P)"
  git() { echo "$wt"; }
  cd "$wt/src"
  run shunt_cw_project_root
  assert_success
  assert_output "$wt"
  CLAUDE_PROJECT_DIR="$wt" run shunt_cw_project_root
  assert_success
  assert_output "$wt"
}

@test "an explicit CLAUDE_PROJECT_DIR is not treated as a cwd fallback" {
  git() { return 128; }
  mkdir -p "$TEST_TMPDIR/fake-home/.config/tool"
  cd "$TEST_TMPDIR/fake-home/.config/tool"
  CLAUDE_PROJECT_DIR="$PROJ" run shunt_cw_project_root
  assert_success
  assert_output "$PROJ"
}

# --- structural target rule: dotted components and a short non-dot list -----

@test "check refuses any dotted component, at any depth and in the not-yet-created tail" {
  local target
  for target in .git/hooks/pre-commit .github/workflows/x.yml .mcp.json .cursorrules .env.local .foo \
      .husky/pre-commit .vscode/tasks.json .npmrc .gitlab-ci.yml .circleci/config.yml .config/a.txt \
      .local/x.txt .gitignore .idea/x.xml sub/.hidden/test_x.py a/b/c/.d/e.txt sub/.envrc; do
    assert_refused_target "$target"
  done
}

@test "check refuses a dotted component that exists on disk and one under a fresh tail" {
  mkdir -p "$PROJ/sub/.hidden"
  assert_refused_target "sub/.hidden/new.txt"
  assert_refused_target "sub/fresh/deeper/.hidden/new.txt"
  assert_refused_target "$PROJ/sub/fresh/.hidden/new.txt"
}

@test "check refuses the short non-dot names case-insensitively and at any depth" {
  local name
  for name in claude.md claude.local.md agents.md gemini.md jenkinsfile opencode.json makefile gnumakefile justfile rakefile vagrantfile conftest.py; do
    assert_refused_target "$name"
    assert_refused_target "sub/$name"
    assert_refused_target "sub/$name/x.txt"
    assert_refused_target "$(printf '%s' "$name" | tr 'a-z' 'A-Z')"
  done
  assert_refused_target "CLAUDE.md"
  assert_refused_target "sub/claude.md"
  assert_refused_target "Makefile"
  assert_refused_target "GEMINI.md"
}

@test "check refuses trailing dot and space variants of refused names" {
  local target
  for target in ".git./x" ".GIT/x" ".Git /x" "a/.github.../x.yml" ".env." "CLAUDE.md." "Makefile " ".foo. ." "sub/... /x"; do
    assert_refused_target "$target"
  done
}

@test "check treats a component of only dots and spaces as dotted" {
  assert_refused_target "..."
  assert_refused_target "sub/.../x.txt"
  assert_refused_target ". ./x.txt"
}

@test "check keeps the split messages for exact . and .. components" {
  run shunt_cw_check_target "$PROJ" "sub/./x.txt"
  assert_failure
  assert_output --partial "'.' component"
  run shunt_cw_check_target "$PROJ" "sub/../x.txt"
  assert_failure
  assert_output --partial "'..' component"
  run shunt_cw_check_target "$PROJ" "sub//x.txt"
  assert_failure
  assert_output --partial "empty component"
}

@test "check still accepts ordinary targets and names with a dot only inside" {
  local target
  for target in tests/test_x.py src/a.b/c.txt foo.test.js docs/notes.md config/a.txt src/local/a.txt \
      docs/agents.txt jenkinsfile.md not-opencode.json.txt makefile.txt my.git/x.txt githooks/a.txt \
      cursor/a.txt npmrc.txt env.txt; do
    run shunt_cw_check_target "$PROJ" "$target"
    assert_success
    assert_output "$PROJ/$target"
  done
}

@test "check refusal message names the component and points to the Write tool" {
  run shunt_cw_check_target "$PROJ" "sub/.hidden/x.py"
  assert_failure
  assert_output --partial "the path component '.hidden' is not allowed"
  assert_output --partial "Write tool"
  run shunt_cw_check_target "$PROJ" "Makefile"
  assert_failure
  assert_output --partial "'makefile'"
  assert_output --partial "Write tool"
}

@test "project root accepts a cwd fallback below a dotted directory outside the root list" {
  git() { return 128; }
  local d
  for d in .cache .dotfiles .idea .cursor .opencode .hidden/proj; do
    mkdir -p "$TEST_TMPDIR/fake-home/$d/work"
    cd "$TEST_TMPDIR/fake-home/$d/work"
    run shunt_cw_project_root
    assert_success
    assert_output "$(cd -P "$TEST_TMPDIR/fake-home/$d/work" && pwd -P)"
  done
}

@test "project root refuses a cwd fallback below a root-list name given with trailing dots or another case" {
  git() { return 128; }
  local d
  for d in .GIT .Claude .ssh. .Config .LOCAL .Aws; do
    mkdir -p "$TEST_TMPDIR/fake-home/$d/work"
    cd "$TEST_TMPDIR/fake-home/$d/work"
    run shunt_cw_project_root
    assert_failure
    assert_output --partial "git work tree"
  done
}

@test "sensitive component names the new credential stores and keeps the old patterns" {
  local name
  for name in .vault-token .VAULT-TOKEN .azure/x prod.tfvars prod.auto.tfvars .password-store/a.gpg .dockercfg .s3cfg .boto \
      .config/gcloud/creds.db application_default_credentials.json ssh_host_ed25519_key ssh_host_rsa_key \
      id_rsa.pub credentials.json server.key .git/config .env; do
    run shunt_cw_sensitive_component "$name"
    assert_success
  done
}

@test "sensitive component does not flag ordinary lookalikes of the new names" {
  local name
  for name in vault-token.md azure/x tfvars.md main.tf .config/other/x .password-store-notes.md dockercfg.md boto.py \
      s3cfg.md ssh_host_notes.txt application_default_credentials.md ssh_host_rsa_key.md.txt; do
    run shunt_cw_sensitive_component "$name"
    assert_failure
  done
}

@test "check refuses invisible, bidi, C1 and control characters in the target under any locale" {
  local loc seq target
  for loc in $(test_locales); do
    for seq in "${INVISIBLE_SEQS[@]}"; do
      target=$(printf "dir/a${seq}b.txt")
      in_locale "$loc" shunt_cw_check_target "$PROJ" "$target"
      assert_failure
      assert_output --partial "refusing target"
    done
    for seq in '\t' '\033' '\177' '\v' '\f' '\r' '\n'; do
      target=$(printf "dir/a${seq}b.txt")
      in_locale "$loc" shunt_cw_check_target "$PROJ" "$target"
      assert_failure
      assert_output --partial "refusing target"
    done
  done
}

@test "check accepts ordinary Unicode in the target under any locale" {
  local loc seq target
  for loc in $(test_locales); do
    for seq in "${PLAIN_UNICODE_SEQS[@]}"; do
      target=$(printf "dir/a${seq}b.txt")
      in_locale "$loc" shunt_cw_check_target "$PROJ" "$target"
      assert_success
    done
  done
}

@test "check refuses an invisible character in the project root under any locale" {
  local loc root
  root="$TEST_TMPDIR/root$(printf '\342\200\256')x"
  mkdir -p "$root"
  for loc in $(test_locales); do
    in_locale "$loc" shunt_cw_check_target "$root" "x.txt"
    assert_failure
    assert_output --partial "control characters"
  done
}

@test "normalize leaves a path with an invisible character for the check to refuse" {
  local path
  path="a/./b$(printf '\342\200\256')/../c.txt"
  run shunt_cw_normalize_path "$path"
  assert_success
  assert_output "$path"
}

@test "strip_invisible removes every invisible class under any locale and keeps the rest" {
  local loc seq
  for loc in $(test_locales); do
    for seq in "${INVISIBLE_SEQS[@]}"; do
      in_locale "$loc" shunt_cw_strip_invisible "$(printf "a${seq}b")"
      assert_success
      assert_output "ab"
    done
    for seq in "${PLAIN_UNICODE_SEQS[@]}"; do
      in_locale "$loc" shunt_cw_strip_invisible "$(printf "a${seq}b")"
      assert_success
      assert_output "$(printf "a${seq}b")"
    done
  done
}

@test "strip_invisible cannot be defeated by nesting one sequence inside another" {
  local loc
  for loc in $(test_locales); do
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\342\342\200\213\200\213b')"
    assert_output "ab"
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\302\302\200\200b')"
    assert_output "ab"
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\363\240\363\240\201\201\201\201b')"
    assert_output "ab"
  done
}

@test "parse marks C1 control characters in CODE and NOTES as unusable under any locale" {
  local loc seq
  for loc in $(test_locales); do
    for seq in '\302\200' '\302\205' '\302\237'; do
      resp_of "" "x = \"a${seq}b\"\n"
      in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
      assert_failure 11
      assert_output "control-characters"
      resp_of "note a${seq}b\n" "code\n"
      in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
      assert_failure 11
      assert_output "control-characters"
    done
  done
}

@test "parse still accepts NBSP, accented and CJK text next to the C1 range under any locale" {
  local loc seq
  for loc in $(test_locales); do
    for seq in '\302\240' '\303\251' '\344\270\255'; do
      resp_of "" "x = \"a${seq}b\"\n"
      in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
      assert_success
    done
  done
}

@test "publish refuses C1 control characters in the content" {
  local before
  printf 'x = "a\302\205b"\n' >"$TEST_TMPDIR/c1"
  before="$(snapshot)"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/c1"
  assert_failure
  assert_output --partial "control-characters"
  [ "$before" = "$(snapshot)" ]
}

# ---------------------------------------------------------------------------
# Security review round 2: invisible characters in generated code, more
# credential stores, more steering files, container secret mounts
# ---------------------------------------------------------------------------

@test "parse marks every invisible character in CODE as unusable except ZWNJ, ZWJ and VS16 under any locale" {
  local loc seq
  for loc in $(test_locales); do
    for seq in $(code_refused_seqs); do
      resp_of "" "x = \"a${seq}b\"\n"
      in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
      assert_failure 11
      assert_output "invisible-characters"
      [ ! -e "$OUT/code" ]
      [ ! -e "$OUT/notes" ]
    done
  done
}

@test "parse marks the Tag block, separators, BOM and format characters in CODE as unusable" {
  local seq
  for seq in '\363\240\201\201' '\363\240\200\200' '\363\240\201\277' '\342\200\250' '\342\200\251' '\357\273\277' \
      '\330\234' '\342\201\240' '\342\201\244' '\342\200\213' '\342\200\216' '\342\200\217'; do
    resp_of "" "x = 1${seq}\n"
    assert_parse_unusable "invisible-characters"
  done
}

@test "parse still accepts ZWJ emoji sequences, ZWNJ, VS16, Cyrillic, CJK and tabs in CODE under any locale" {
  local loc
  for loc in $(test_locales); do
    resp_of '' '\tfamily = "\360\237\221\250\342\200\215\360\237\221\251\342\200\215\360\237\221\247"\n'
    in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
    assert_success
    resp_of '' 'heart = "\342\235\244\357\270\217"\nzwnj = "a\342\200\214b"\n'
    in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
    assert_success
    resp_of '' '# \320\237\321\200\320\270\320\262\320\265\321\202 \344\270\226\347\225\214\n\tx = 1\n'
    in_locale "$loc" shunt_cw_parse "$RESP" "$OUT"
    assert_success
    [ -s "$OUT/code" ]
  done
}

@test "parse keeps invisible characters in NOTES and leaves stripping to the printer" {
  local seq notes=""
  for seq in $(code_refused_seqs) '\342\200\214' '\342\200\215' '\357\270\217'; do
    notes="$notes$(printf "$seq")"
  done
  resp_of "keep${notes}this\n" 'x = 1\n'
  run shunt_cw_parse "$RESP" "$OUT"
  assert_success
  [ "$(shunt_cw_strip_invisible "$(cat "$OUT/notes")")" = "keepthis" ]
}

@test "publish refuses invisible characters in the content and still writes a ZWJ emoji" {
  local before seq
  # The input file lives in TEST_TMPDIR too, so it must exist before the
  # snapshot, otherwise creating it would look like a leftover of the publish.
  : >"$TEST_TMPDIR/inv"
  before="$(snapshot)"
  for seq in '\363\240\201\201' '\342\200\213' '\357\273\277' '\342\200\250' '\341\240\216'; do
    printf "x = \"a${seq}b\"\n" >"$TEST_TMPDIR/inv"
    run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/inv"
    assert_failure
    assert_output --partial "invisible-characters"
  done
  [ "$before" = "$(snapshot)" ]
  printf 'x = "\360\237\221\250\342\200\215\360\237\221\251"\n' >"$TEST_TMPDIR/zwj"
  run shunt_cw_publish "$PROJ" "newdir/x.txt" "$TEST_TMPDIR/zwj"
  assert_success
  [ -f "$PROJ/newdir/x.txt" ]
}

@test "strip_invisible cannot be defeated by nesting the added sequences" {
  local loc
  for loc in $(test_locales); do
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\341\205\302\255\237b')"
    assert_output "ab"
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\363\240\204\363\240\201\201\200b')"
    assert_output "ab"
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\357\270\357\270\217\217b')"
    assert_output "ab"
    in_locale "$loc" shunt_cw_strip_invisible "$(printf 'a\360\235\205\342\201\240\263b')"
    assert_output "ab"
  done
}

@test "sensitive component names the secret, cloud, package and tool config stores added later" {
  local name
  for name in secrets.json secrets.yml secrets.yaml SECRETS.YAML .dev.vars .dev.vars.production serviceAccountKey.json \
      gcp-credentials.json my-app-credentials.json client_secret_123.apps.json firebase-adminsdk-abc.json \
      wrangler.toml local.settings.json .yarnrc .yarnrc.yml .gitconfig .my.cnf _netrc .authinfo .authinfo.gpg \
      key.gpg id.ppk AuthKey_X.p8 pub.asc client.ovpn .terraformrc .composer/auth.json .m2/settings.xml \
      .claude.json .config/rclone/rclone.conf .config/doctl/config.yaml .config/heroku/x .config/op/x .config/sops/age/keys.txt \
      sub/.Composer/Auth.json home/u/.M2/settings.xml; do
    run shunt_cw_sensitive_component "$name"
    assert_success
  done
}

@test "sensitive component does not flag lookalikes of the later additions" {
  local name
  for name in secrets.md secretsjson.txt my-credentials.md client_secret.md client-secret-x.json firebase-adminsdk.md \
      wrangler.toml.md local.settings.md yarnrc.md gitconfig.md my.cnf.bak netrc _netrc.md authinfo.md gpg.md \
      notes.asc.md ovpn.md terraformrc.md auth.json settings.xml pom.xml .composer/composer.json .m2/pom.xml \
      claude.json .config/other/x rclone/x op/x sops/x; do
    run shunt_cw_sensitive_component "$name"
    assert_failure
  done
}
