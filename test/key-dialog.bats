load 'test_helper'
# Launcher-level checks. The dialog behaviour is covered by test/py/test_key_dialog.py.

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
}

@test "a missing provider argument is a usage error" {
  run "$DIALOG_BIN"
  [ "$status" -eq 2 ]
}

@test "a BASH_ENV that turns on xtrace does not leak the key through the passed-through store stderr" {
  export HOME="$TEST_TMPDIR/home" XDG_CONFIG_HOME="$TEST_TMPDIR/xdg-config" XDG_DATA_HOME="$TEST_TMPDIR/xdg-data" XDG_CACHE_HOME="$TEST_TMPDIR/xdg-cache" TMPDIR="$TEST_TMPDIR"
  mkdir -p "$HOME"
  echo 'set -x' >"$TEST_TMPDIR/bash-env"
  BASH_ENV="$TEST_TMPDIR/bash-env" run --separate-stderr "$DIALOG_BIN" plain
  [[ "$stderr" != *"$SECRET"* ]]
}

@test "shunt-models drops BASH_ENV and ENV for its children" {
  local real_py
  real_py=$(command -v python3)
  cat >"$STUB_BIN/py-spy" <<STUB
#!/bin/bash
echo "\${BASH_ENV:-unset} \${ENV:-unset}" >>"$TEST_TMPDIR/jq-env"
exec "$real_py" "\$@"
STUB
  chmod +x "$STUB_BIN/py-spy"
  export SHUNT_PYTHON="$STUB_BIN/py-spy"
  echo '{"version":1,"providers":{"p":{"transport":"http","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  BASH_ENV=/dev/null ENV=/dev/null run "$REPO_ROOT/scripts/shunt-models" key status p
  [ -s "$TEST_TMPDIR/jq-env" ]
  ! grep -qv '^unset unset$' "$TEST_TMPDIR/jq-env"
}
