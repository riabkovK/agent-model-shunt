load 'test_helper'

setup() {
  shunt_test_setup
  source "$REPO_ROOT/scripts/lib/orchestrator.sh"
  mkdir -p "$TEST_TMPDIR/frag"
}

teardown() {
  shunt_test_teardown
}

# frag <name> <printf-format> [args]: writes $TEST_TMPDIR/frag/<name>.
frag() {
  local name="$1"
  shift
  printf "$@" >"$TEST_TMPDIR/frag/$name"
}

@test "built-in fragments parse with their roles" {
  run shunt_orchestrator_role "$REPO_ROOT/skills/bulk-reader/orchestrator.md"
  [ "$status" -eq 0 ]
  [ "$output" = "bulk-read" ]
  run shunt_orchestrator_role "$REPO_ROOT/skills/code-writer/orchestrator.md"
  [ "$status" -eq 0 ]
  [ "$output" = "code-write" ]
  run shunt_orchestrator_body "$REPO_ROOT/skills/bulk-reader/orchestrator.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/bulk-reader"* ]]
  run shunt_orchestrator_body "$REPO_ROOT/skills/code-writer/orchestrator.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/code-writer"* ]]
}

@test "built-in roles are known registry roles" {
  source "$REPO_ROOT/scripts/lib/models.sh"
  local f role
  for f in $(shunt_orchestrator_list); do
    role=$(shunt_orchestrator_role "$f")
    shunt_models_role_known "$role"
  done
}

@test "MIN_LINES is substituted in the body" {
  run shunt_orchestrator_body "$REPO_ROOT/skills/bulk-reader/orchestrator.md" 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"over 500 lines"* ]]
  [[ "$output" != *"{{MIN_LINES}}"* ]]
}

@test "garbage MIN_LINES falls back to 350" {
  local v
  for v in "" abc "1;ls" '$(id)' -5 0 00 1234567890 "3 5"; do
    run shunt_orchestrator_body "$REPO_ROOT/skills/bulk-reader/orchestrator.md" "$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"over 350 lines"* ]]
  done
}

@test "a fragment without a role line has an empty role" {
  frag f -- '- one\n- two\n'
  run shunt_orchestrator_role "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "other tokens are not substituted" {
  frag f -- '- {{OTHER}} ${HOME} {{MIN_LINES}}x\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f" 9
  [ "$output" = '- {{OTHER}} ${HOME} 9x' ]
}

@test "blank lines are ignored" {
  frag f 'role: bulk-read\n\n- a\n   \n- b\n\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "$output" = $'- a\n- b' ]
}

@test "invalid role lines reject the fragment" {
  local r
  for r in 'role: Bad' 'role: a b' 'role: ' 'role: x;id' 'role: -x' 'role: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
    frag f '%s\n- a\n' "$r"
    run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run shunt_orchestrator_role "$TEST_TMPDIR/frag/f"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "a role line that is not first is rejected" {
  frag f -- '- a\nrole: bulk-read\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -ne 0 ]
}

@test "a non-bullet line rejects the fragment" {
  frag f 'role: bulk-read\n- a\nplain text\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "seven bullets are rejected and six are accepted" {
  frag f -- '- 1\n- 2\n- 3\n- 4\n- 5\n- 6\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  frag f -- '- 1\n- 2\n- 3\n- 4\n- 5\n- 6\n- 7\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "an empty body is rejected" {
  frag f ''
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -ne 0 ]
  frag f 'role: bulk-read\n\n\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -ne 0 ]
}

@test "a directory, a missing file and an oversize file are rejected" {
  mkdir "$TEST_TMPDIR/frag/dir"
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/dir"
  [ "$status" -ne 0 ]
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/missing"
  [ "$status" -ne 0 ]
  { printf -- '- a\n'; head -c 5000 /dev/zero | tr '\0' ' '; } >"$TEST_TMPDIR/frag/big"
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/big"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "control characters, ANSI sequences and CR are stripped" {
  frag f -- '- a\033[31mred\033[0m\tb\r\n- c\001d\033]0;title\007e\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "$output" = $'- ared b\n- cde' ]
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *$'\r'* ]]
  [[ "$output" != *$'\001'* ]]
  [[ "$output" != *$'\t'* ]]
}

@test "UTF-8 text is kept" {
  frag f -- '- привет мир, café\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$output" = '- привет мир, café' ]
}

@test "a long line is truncated to 160 characters" {
  local long
  long=$(head -c 400 /dev/zero | tr '\0' 'x')
  frag f -- '- %s\n' "$long"
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 160 ]
}

@test "a long body is truncated to 600 characters" {
  local l
  l=$(head -c 150 /dev/zero | tr '\0' 'y')
  frag f -- '- %s\n- %s\n- %s\n- %s\n- %s\n- %s\n' "$l" "$l" "$l" "$l" "$l" "$l"
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 600 ]
}

@test "command substitution and backticks in a fragment are printed literally" {
  cd "$TEST_TMPDIR"
  frag f -- '- $(touch pwned) `touch pwned2` ${IFS} $((1+1))\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "$output" = '- $(touch pwned) `touch pwned2` ${IFS} $((1+1))' ]
  [ ! -e pwned ]
  [ ! -e pwned2 ]
}

@test "listing finds built-in fragments sorted" {
  run shunt_orchestrator_list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$output" | LC_ALL=C sort)" ]
  [[ "$output" == *"skills/bulk-reader/orchestrator.md"* ]]
  [[ "$output" == *"skills/code-writer/orchestrator.md"* ]]
}

@test "listing sorts a custom root and ignores skills without a fragment" {
  local r="$TEST_TMPDIR/root"
  mkdir -p "$r/skills/zeta" "$r/skills/alpha" "$r/skills/none"
  : >"$r/skills/zeta/orchestrator.md"
  : >"$r/skills/alpha/orchestrator.md"
  run shunt_orchestrator_list "$r"
  [ "$output" = "$r/skills/alpha/orchestrator.md"$'\n'"$r/skills/zeta/orchestrator.md" ]
}

@test "listing an empty root prints nothing" {
  run shunt_orchestrator_list "$TEST_TMPDIR/nothing"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invisible and terminal-active Unicode is stripped" {
  frag f -- '- a\302\233b\342\200\256c\342\200\213d\357\273\277e\363\240\201\251f\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -eq 0 ]
  [ "$output" = '- abcdef' ]
}

@test "OSC terminated by ST is stripped with its payload" {
  frag f -- '- a\033]0;title\033\\b\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$output" = '- ab' ]
}

@test "role names are lowercase only whatever the locale" {
  frag f 'role: Bad\n- a\n'
  LC_ALL=en_US.UTF-8 run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$status" -ne 0 ]
}

@test "the file size cap is exactly 4096 bytes" {
  { printf -- '- a'; head -c 4093 /dev/zero | tr '\0' ' '; } >"$TEST_TMPDIR/frag/ok"
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/ok"
  [ "$status" -eq 0 ]
  { printf -- '- a'; head -c 4094 /dev/zero | tr '\0' ' '; } >"$TEST_TMPDIR/frag/big"
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/big"
  [ "$status" -ne 0 ]
}

@test "leading zeros and the 9-digit limit in MIN_LINES" {
  frag f -- '- {{MIN_LINES}}\n'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f" 0007
  [ "$output" = '- 7' ]
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f" 999999999
  [ "$output" = '- 999999999' ]
}

@test "a file without a trailing newline parses" {
  frag f -- '- a'
  run shunt_orchestrator_body "$TEST_TMPDIR/frag/f"
  [ "$output" = '- a' ]
}

# udir_frag <name> <printf-format> [args]: writes into the user fragment dir.
udir_frag() {
  local name="$1"
  shift
  mkdir -p "$SHUNT_ORCHESTRATOR_DIR"
  printf "$@" >"$SHUNT_ORCHESTRATOR_DIR/$name"
}

@test "user fragments are listed after the built-ins" {
  udir_frag mine.md -- '- my rule\n'
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 3 ]
  assert_line --index 0 --regexp 'skills/bulk-reader/orchestrator.md$'
  assert_line --index 1 --regexp 'skills/code-writer/orchestrator.md$'
  assert_line --index 2 "$SHUNT_ORCHESTRATOR_DIR/mine.md"
}

@test "user fragments are sorted by basename in the C locale" {
  udir_frag b.md -- '- b\n'
  udir_frag B.md -- '- B\n'
  udir_frag a.md -- '- a\n'
  run shunt_orchestrator_list
  assert_success
  assert_line --index 2 "$SHUNT_ORCHESTRATOR_DIR/B.md"
  assert_line --index 3 "$SHUNT_ORCHESTRATOR_DIR/a.md"
  assert_line --index 4 "$SHUNT_ORCHESTRATOR_DIR/b.md"
}

@test "a user fragment named like a built-in skill replaces it" {
  udir_frag bulk-reader.md -- 'role: bulk-read\n- custom bulk rule\n'
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 2 ]
  assert_line --index 0 --regexp 'skills/code-writer/orchestrator.md$'
  assert_line --index 1 "$SHUNT_ORCHESTRATOR_DIR/bulk-reader.md"
}

@test "the default override name is the skill directory name, not orchestrator.md" {
  udir_frag orchestrator.md -- '- plain\n'
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 3 ]
}

@test "symlinks, directories, FIFOs, non-md files and dotfiles are skipped" {
  mkdir -p "$SHUNT_ORCHESTRATOR_DIR/dir.md"
  mkfifo "$SHUNT_ORCHESTRATOR_DIR/fifo.md"
  udir_frag real.md -- '- real\n'
  udir_frag notes.txt -- '- txt\n'
  udir_frag .hidden.md -- '- hidden\n'
  udir_frag .md -- '- dot\n'
  ln -s "$SHUNT_ORCHESTRATOR_DIR/real.md" "$SHUNT_ORCHESTRATOR_DIR/link.md"
  ln -s /nonexistent "$SHUNT_ORCHESTRATOR_DIR/dangling.md"
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 3 ]
  assert_line --index 2 "$SHUNT_ORCHESTRATOR_DIR/real.md"
}

@test "a missing fragment dir is fine" {
  export SHUNT_ORCHESTRATOR_DIR="$TEST_TMPDIR/nope"
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 2 ]
}

@test "an unreadable or non-directory fragment path is skipped silently" {
  printf 'x' >"$TEST_TMPDIR/afile"
  export SHUNT_ORCHESTRATOR_DIR="$TEST_TMPDIR/afile"
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 2 ]
  [ -z "$(shunt_orchestrator_list 2>&1 >/dev/null)" ]
}

@test "at most 16 user fragments are listed" {
  local i
  for i in $(seq -w 1 40); do udir_frag "f$i.md" -- '- x\n'; done
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 18 ]
  assert_line --index 2 "$SHUNT_ORCHESTRATOR_DIR/f01.md"
  assert_line --index 17 "$SHUNT_ORCHESTRATOR_DIR/f16.md"
}

@test "filenames with a newline are skipped" {
  udir_frag $'a\nb.md' -- '- nl\n'
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 2 ]
}

@test "the default fragment dir follows XDG_CONFIG_HOME, then HOME" {
  unset SHUNT_ORCHESTRATOR_DIR
  mkdir -p "$XDG_CONFIG_HOME/agent-model-shunt/orchestrator.d" "$HOME/.config/agent-model-shunt/orchestrator.d"
  printf -- '- xdg\n' >"$XDG_CONFIG_HOME/agent-model-shunt/orchestrator.d/x.md"
  printf -- '- home\n' >"$HOME/.config/agent-model-shunt/orchestrator.d/h.md"
  run shunt_orchestrator_list
  assert_success
  assert_line "$XDG_CONFIG_HOME/agent-model-shunt/orchestrator.d/x.md"
  refute_output --partial "h.md"
  unset XDG_CONFIG_HOME
  run shunt_orchestrator_list
  assert_success
  assert_line "$HOME/.config/agent-model-shunt/orchestrator.d/h.md"
}

@test "test isolation points HOME and the XDG dirs into the temp dir" {
  [[ "$HOME" == "$TEST_TMPDIR"/* ]]
  [[ "$XDG_CONFIG_HOME" == "$TEST_TMPDIR"/* ]]
  [[ "$XDG_STATE_HOME" == "$TEST_TMPDIR"/* ]]
  [[ "$XDG_CACHE_HOME" == "$TEST_TMPDIR"/* ]]
  [[ "$TMPDIR" == "$TEST_TMPDIR"/* ]]
  [ -d "$TMPDIR" ]
}

@test "invalid user files do not crowd out valid fragments within the candidate cap" {
  local i
  for i in $(seq -w 1 20); do udir_frag "a$i.md" -- 'junk\n'; done
  udir_frag z.md -- '- valid\n'
  run shunt_orchestrator_list
  assert_success
  assert_line "$SHUNT_ORCHESTRATOR_DIR/z.md"
}

@test "an invalid user override keeps the built-in" {
  udir_frag bulk-reader.md -- 'garbage\n'
  run shunt_orchestrator_list
  assert_success
  [ "${#lines[@]}" -eq 2 ]
  assert_line --index 0 --regexp 'skills/bulk-reader/orchestrator.md$'
}

@test "a relative or group/world-writable fragment dir is ignored" {
  udir_frag mine.md -- '- mine\n'
  chmod 777 "$SHUNT_ORCHESTRATOR_DIR"
  run shunt_orchestrator_list
  [ "${#lines[@]}" -eq 2 ]
  chmod 755 "$SHUNT_ORCHESTRATOR_DIR"
  cd "$TEST_TMPDIR"
  SHUNT_ORCHESTRATOR_DIR=orchestrator.d run shunt_orchestrator_list
  [ "${#lines[@]}" -eq 2 ]
}

# Drift guard. A skill "delegates to a model" when its SKILL.md runs one of the
# delegation scripts as a command at the start of a line (scripts/bulk-read or
# scripts/code-write followed by arguments). Prose mentions, such as the
# management skills describing those scripts inline, do not start a line with
# the path, so they are not matched. Every delegating skill must register an
# orchestrator.md next to its SKILL.md.
@test "every delegating skill has an orchestrator.md with a registry role" {
  source "$REPO_ROOT/scripts/lib/models.sh"
  local skill dir found=0
  for skill in "$REPO_ROOT"/skills/*/SKILL.md; do
    grep -qE '^scripts/(bulk-read|code-write) ' "$skill" || continue
    found=$((found + 1))
    dir="${skill%/SKILL.md}"
    [ -f "$dir/orchestrator.md" ] || { echo "missing orchestrator.md in $dir"; return 1; }
    run shunt_orchestrator_role "$dir/orchestrator.md"
    [ "$status" -eq 0 ] || { echo "invalid fragment in $dir"; return 1; }
    [ -n "$output" ] || { echo "no role in $dir"; return 1; }
    shunt_models_role_known "$output" || { echo "unknown role $output in $dir"; return 1; }
  done
  [ "$found" -ge 2 ]
}

@test "every built-in fragment declares a known registry role" {
  source "$REPO_ROOT/scripts/lib/models.sh"
  local f
  for f in "$REPO_ROOT"/skills/*/orchestrator.md; do
    run shunt_orchestrator_role "$f"
    [ "$status" -eq 0 ] || { echo "invalid fragment $f"; return 1; }
    shunt_models_role_known "$output" || { echo "unknown role '$output' in $f"; return 1; }
  done
}
