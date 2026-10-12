load 'test_helper'

bats_require_minimum_version 1.5.0

DIALOG_BIN="$REPO_ROOT/scripts/shunt-key-dialog"
SECRET="sk-test-SECRET-1234567890"

setup() {
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  # Stub dialogs print $STUB_KEY and exit with $STUB_RC. They log their argv
  # so tests can check the key never appears there.
  local tool
  for tool in zenity kdialog osascript; do
    cat >"$STUB_BIN/$tool" <<'STUB'
#!/bin/bash
echo "$0 $*" >>"$STUB_ARGV_LOG"
printf '%s' "${STUB_KEY:-}"
exit "${STUB_RC:-0}"
STUB
    chmod +x "$STUB_BIN/$tool"
  done
  export STUB_ARGV_LOG="$TEST_TMPDIR/argv.log"
  : >"$STUB_ARGV_LOG"
  export STUB_KEY="$SECRET"
  export STUB_RC=0
  export SHUNT_KEY_DIALOG=zenity
  echo '{"version":1,"providers":{
    "plain":{"transport":"http","base_url":"https://x.test/v1","key":{"type":"plaintext"}},
    "envp":{"transport":"http","base_url":"https://x.test/v1","key":{"type":"env","ref":"ENVP_KEY"}},
    "nokey":{"transport":"http","base_url":"https://x.test/v1","key":{"type":"none"}}}}' \
    >"$SHUNT_PROVIDERS_FILE"
}

teardown() {
  shunt_test_teardown
}

stored_key() { jq -r '.providers.plain.key.ref // ""' "$SHUNT_PROVIDERS_FILE"; }

@test "success stores the key and the output never contains it" {
  run --separate-stderr "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "$SECRET" ]
  [[ "$output" == *"yes (type plaintext)"* ]]
  [[ "$output" != *"$SECRET"* ]]
  [[ "$stderr" != *"$SECRET"* ]]
}

@test "the key never appears in a dialog or script argument" {
  run "$DIALOG_BIN" plain
  assert_success
  ! grep -qF "$SECRET" "$STUB_ARGV_LOG"
  grep -q -- "--password" "$STUB_ARGV_LOG"
  grep -q -- "--timeout=120" "$STUB_ARGV_LOG"
  grep -q "plain" "$STUB_ARGV_LOG"
}

@test "SHUNT_KEY_DIALOG_TIMEOUT overrides the dialog timeout" {
  SHUNT_KEY_DIALOG_TIMEOUT=7 run "$DIALOG_BIN" plain
  assert_success
  grep -q -- "--timeout=7" "$STUB_ARGV_LOG"
}

@test "kdialog and osascript overrides store the key" {
  SHUNT_KEY_DIALOG=kdialog run "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "$SECRET" ]
  STUB_KEY="second-key" SHUNT_KEY_DIALOG=osascript run "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "second-key" ]
}

@test "cancel exits 3 and stores nothing" {
  STUB_KEY="" STUB_RC=1 run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no key entered"* ]]
  [ -z "$(stored_key)" ]
}

@test "cancel with partial output still stores nothing" {
  STUB_RC=1 run "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
  [ -z "$(stored_key)" ]
}

@test "empty input exits 3 and stores nothing" {
  STUB_KEY="" run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no key entered"* ]]
  [ -z "$(stored_key)" ]
}

@test "a dialog timeout exits 4 and stores nothing" {
  STUB_KEY="" STUB_RC=5 run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"timed out"* ]]
  [ -z "$(stored_key)" ]
}

@test "no dialog exits 5 and prints the absolute fallback line" {
  SHUNT_KEY_DIALOG=none run "$DIALOG_BIN" plain
  [ "$status" -eq 5 ]
  assert_output --partial "! $REPO_ROOT/scripts/shunt-models key set plain"
  [ -z "$(stored_key)" ]
}

@test "auto mode without DISPLAY or WAYLAND_DISPLAY finds no dialog on Linux" {
  [ "$(uname -s)" = Linux ] || skip "Linux only"
  unset SHUNT_KEY_DIALOG DISPLAY WAYLAND_DISPLAY
  run "$DIALOG_BIN" plain
  [ "$status" -eq 5 ]
}

@test "auto mode with DISPLAY picks zenity on Linux" {
  [ "$(uname -s)" = Linux ] || skip "Linux only"
  unset SHUNT_KEY_DIALOG WAYLAND_DISPLAY
  DISPLAY=:0 run "$DIALOG_BIN" plain
  assert_success
  grep -q "zenity" "$STUB_ARGV_LOG"
  [ "$(stored_key)" = "$SECRET" ]
}

@test "env key type is refused with exit 1" {
  run "$DIALOG_BIN" envp
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_ARGV_LOG" ]
}

@test "none key type is refused with exit 1" {
  run "$DIALOG_BIN" nokey
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_ARGV_LOG" ]
}

@test "unknown provider is refused with exit 1" {
  run "$DIALOG_BIN" ghost
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_ARGV_LOG" ]
}

@test "a missing provider argument is a usage error" {
  run "$DIALOG_BIN"
  [ "$status" -eq 2 ]
}

@test "a key wrapped in double quotes is stored unquoted" {
  STUB_KEY="\"$SECRET\"" run --separate-stderr "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "$SECRET" ]
}

@test "a key wrapped in single quotes is stored unquoted" {
  STUB_KEY="'$SECRET'" run --separate-stderr "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "$SECRET" ]
}

@test "surrounding whitespace, tabs and CR are trimmed, also around quotes" {
  STUB_KEY=$' \t "'"$SECRET"$'" \r' run --separate-stderr "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "$SECRET" ]
}

@test "internal and unmatched quotes are preserved" {
  STUB_KEY="ab\"cd'ef" run "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "ab\"cd'ef" ]
  STUB_KEY="\"abc'" run "$DIALOG_BIN" plain
  assert_success
  [ "$(stored_key)" = "\"abc'" ]
}

@test "a key that is only whitespace or empty quotes counts as no key" {
  STUB_KEY=$'  \t ' run "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
  STUB_KEY='""' run "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
  [ -z "$(stored_key)" ]
}

@test "a quoted key never appears in output" {
  STUB_KEY="\"$SECRET\"" run --separate-stderr "$DIALOG_BIN" plain
  [[ "$output" != *"$SECRET"* ]]
  [[ "$stderr" != *"$SECRET"* ]]
}

@test "an osascript dialog that gave up exits 4 (timeout), not 3 (cancel)" {
  STUB_KEY="__SHUNT_DIALOG_GAVE_UP__" SHUNT_KEY_DIALOG=osascript run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"timed out"* ]]
  [ -z "$(stored_key)" ]
}

@test "an osascript dialog the user cancelled still exits 3" {
  STUB_KEY="" STUB_RC=1 SHUNT_KEY_DIALOG=osascript run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
}

@test "a failing store passes the shunt-models error through without the key" {
  # Under WSL there is no keyring backend, so `key set` refuses a keyring key.
  echo "Linux version 5 microsoft" >"$TEST_TMPDIR/proc-version"
  echo '{"version":1,"providers":{"kr":{"transport":"http","base_url":"https://x.test/v1","key":{"type":"keyring"}}}}' >"$SHUNT_PROVIDERS_FILE"
  SHUNT_PROC_VERSION_FILE="$TEST_TMPDIR/proc-version" run --separate-stderr "$DIALOG_BIN" kr
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"no keyring backend"* ]]
  [[ "$stderr" != *"$SECRET"* ]]
}

@test "a BASH_ENV that turns on xtrace does not leak the key through the passed-through store stderr" {
  export HOME="$TEST_TMPDIR/home" XDG_CONFIG_HOME="$TEST_TMPDIR/xdg-config" XDG_DATA_HOME="$TEST_TMPDIR/xdg-data" XDG_CACHE_HOME="$TEST_TMPDIR/xdg-cache" TMPDIR="$TEST_TMPDIR"
  mkdir -p "$HOME"
  echo 'set -x' >"$TEST_TMPDIR/bash-env"
  BASH_ENV="$TEST_TMPDIR/bash-env" run --separate-stderr "$DIALOG_BIN" plain
  [[ "$stderr" != *"$SECRET"* ]]
}

@test "a hostile provider name is refused before any dialog opens" {
  local name
  for name in 'a;rm -rf x' '$(id)' 'a b' '-x' 'a`id`'; do
    run "$DIALOG_BIN" "$name"
    [ "$status" -eq 1 ]
    assert_output --partial "invalid provider name"
    [ ! -s "$STUB_ARGV_LOG" ]
  done
}

@test "a pasted key with a line break is refused and nothing is stored" {
  STUB_KEY=$'sk-first\nsk-second' run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"line break"* ]]
  [[ "$stderr" != *"sk-first"* ]]
  [ -z "$(stored_key)" ]
}

@test "dialog stderr is discarded and stdout still carries the key" {
  cat >"$STUB_BIN/zenity" <<'STUB'
#!/bin/bash
echo "gtk noise" >&2
printf '%s' "$STUB_KEY"
STUB
  run --separate-stderr "$DIALOG_BIN" plain
  assert_success
  [[ "$stderr" != *"gtk noise"* ]]
  [ "$(stored_key)" = "$SECRET" ]
}

@test "auto mode over SSH opens no GUI dialog and prints the fallback line" {
  [ "$(uname -s)" = Linux ] || skip "Linux only"
  unset SHUNT_KEY_DIALOG WAYLAND_DISPLAY
  local v
  for v in SSH_CONNECTION SSH_TTY; do
    env "$v=x" DISPLAY=:0 "$DIALOG_BIN" plain >"$TEST_TMPDIR/out" || rc=$?
    [ "${rc:-0}" -eq 5 ]
    grep -q "key set plain" "$TEST_TMPDIR/out"
    [ ! -s "$STUB_ARGV_LOG" ]
    rc=0
  done
}

@test "kdialog without a timeout binary is not used, the fallback line is printed" {
  local d="$TEST_TMPDIR/minbin" t
  mkdir -p "$d"
  for t in jq env uname dirname cat rm mkdir mktemp head tr chmod stat sleep flock python3; do
    command -v "$t" >/dev/null 2>&1 && ln -s "$(command -v "$t")" "$d/$t"
  done
  ln -s "$STUB_BIN/kdialog" "$d/kdialog"
  SHUNT_KEY_DIALOG=kdialog PATH="$d" run /bin/bash "$DIALOG_BIN" plain
  [ "$status" -eq 5 ]
  [ ! -s "$STUB_ARGV_LOG" ]
}

@test "shunt-models drops BASH_ENV and ENV for its children" {
  local real_jq
  real_jq=$(command -v jq)
  cat >"$STUB_BIN/jq" <<STUB
#!/bin/bash
echo "\${BASH_ENV:-unset} \${ENV:-unset}" >>"$TEST_TMPDIR/jq-env"
exec "$real_jq" "\$@"
STUB
  chmod +x "$STUB_BIN/jq"
  echo '{"version":1,"providers":{"p":{"transport":"http","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  BASH_ENV=/dev/null ENV=/dev/null run "$REPO_ROOT/scripts/shunt-models" key status p
  [ -s "$TEST_TMPDIR/jq-env" ]
  ! grep -qv '^unset unset$' "$TEST_TMPDIR/jq-env"
}

@test "a dialog request for an existing entry with a rejected name says to edit providers.json" {
  echo '{"version":1,"providers":{"_old":{"transport":"http","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$DIALOG_BIN" _old
  [ "$status" -eq 1 ]
  assert_output --partial "edit providers.json"
  [ ! -s "$STUB_ARGV_LOG" ]
}

@test "auto mode over SSH says why no window opened and how to force one" {
  [ "$(uname -s)" = Linux ] || skip "Linux only"
  unset SHUNT_KEY_DIALOG WAYLAND_DISPLAY
  SSH_CONNECTION=x DISPLAY=:0 run --separate-stderr "$DIALOG_BIN" plain
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"SSH"* ]]
  [[ "$stderr" == *"SHUNT_KEY_DIALOG=zenity"* ]]
}
