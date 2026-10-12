load 'test_helper'

SHUNT_MODELS_BIN="$REPO_ROOT/scripts/shunt-models"

setup() {
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export SHUNT_PROC_VERSION_FILE="$TEST_TMPDIR/proc-version"
  echo "Linux version 6.1" >"$SHUNT_PROC_VERSION_FILE"
  SECRET="sk-super-secret-value-123"
}

teardown() {
  shunt_test_teardown
}

@test "key set stores a plaintext key from piped stdin with mode 600 and does not echo it" {
  echo '{"version":1,"providers":{"p":{"transport":"http","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run bash -c "printf '%s\n' '$SECRET' | '$SHUNT_MODELS_BIN' key set p"
  assert_success
  refute_output --partial "$SECRET"
  assert_output --partial "plain text"
  [ "$(stat -c %a "$SHUNT_PROVIDERS_FILE")" = "600" ]
  run jq -r '.providers.p.key.ref' "$SHUNT_PROVIDERS_FILE"
  assert_output "$SECRET"
}

@test "key set refuses an env-type provider" {
  echo '{"providers":{"p":{"key":{"type":"env","ref":"X_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run bash -c "echo '$SECRET' | '$SHUNT_MODELS_BIN' key set p"
  assert_failure
  assert_output --partial "env key"
  refute_output --partial "$SECRET"
}

@test "key set refuses a none-type provider" {
  echo '{"providers":{"p":{"key":{"type":"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run bash -c "echo '$SECRET' | '$SHUNT_MODELS_BIN' key set p"
  assert_failure
  assert_output --partial "type none"
}

@test "key set for an unknown provider fails" {
  echo '{"providers":{}}' >"$SHUNT_PROVIDERS_FILE"
  run bash -c "echo '$SECRET' | '$SHUNT_MODELS_BIN' key set nope"
  assert_failure
  assert_output --partial "not in"
}

@test "key set refuses an empty key" {
  echo '{"providers":{"p":{"key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run bash -c "echo '' | '$SHUNT_MODELS_BIN' key set p"
  assert_failure
  assert_output --partial "empty key"
}

@test "key set with keyring type and no backend fails clearly" {
  echo '{"providers":{"p":{"key":{"type":"keyring"}}}}' >"$SHUNT_PROVIDERS_FILE"
  echo "Linux version 5 microsoft" >"$SHUNT_PROC_VERSION_FILE"
  run bash -c "echo '$SECRET' | '$SHUNT_MODELS_BIN' key set p"
  assert_failure
  assert_output --partial "no keyring backend"
}

@test "key set stores into the keyring via stdin, never argv" {
  local bin="$TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/secret-tool" <<'SH'
#!/bin/bash
echo "$*" >>"$FAKE_ARGV"
[ "$1" = store ] && cat >"$FAKE_STORE"
SH
  chmod +x "$bin/secret-tool"
  export FAKE_ARGV="$TEST_TMPDIR/argv" FAKE_STORE="$TEST_TMPDIR/store"
  echo '{"providers":{"p":{"key":{"type":"keyring"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run env PATH="$bin:$PATH" bash -c "echo '$SECRET' | '$SHUNT_MODELS_BIN' key set p"
  assert_success
  refute_output --partial "$SECRET"
  [ "$(cat "$FAKE_STORE")" = "$SECRET" ]
  run grep -c "$SECRET" "$FAKE_ARGV"
  assert_output "0"
}

@test "key status reports yes for a resolvable env key without the value" {
  echo '{"providers":{"p":{"key":{"type":"env","ref":"X_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  X_KEY="$SECRET" run "$SHUNT_MODELS_BIN" key status p
  assert_success
  assert_output --partial "yes (type env)"
  refute_output --partial "$SECRET"
}

@test "key status reports no when the env variable is unset" {
  echo '{"providers":{"p":{"key":{"type":"env","ref":"X_KEY_UNSET"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" key status p
  assert_success
  assert_output --partial "no (type env)"
}

@test "key status for type none says no key is needed" {
  echo '{"providers":{"p":{"key":{"type":"none"}}}}' >"$SHUNT_PROVIDERS_FILE"
  run "$SHUNT_MODELS_BIN" key status p
  assert_output --partial "yes (type none"
}

@test "key set racing a provider set to env never stores the key as the env ref" {
  command -v flock >/dev/null || skip "flock not available"
  # An alphanumeric key (e.g. a 32-char Mistral-style key) is also a valid
  # environment variable name, so the entry would still validate.
  local key="abcDEF0123456789abcdef0123456789"
  echo '{"version":1,"providers":{"p":{"transport":"http","base_url":"https://p.test/v1","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  # Hold the providers lock, as a concurrent `provider set` would.
  exec 9>>"$SHUNT_PROVIDERS_FILE.lock"
  flock -x 9
  SHUNT_PROVIDERS_LOCK_TIMEOUT=37 bash -c "printf '%s\n' '$key' | '$SHUNT_MODELS_BIN' key set p" >/dev/null 2>&1 &
  local bg=$! i waiting=0
  # The lock is polled by the Python writer (no sleep child to look for), so a
  # waiting key set is a running providers-write plaintext-store process.
  for i in $(seq 1 100); do
    pgrep -f "providers-write plaintext-store" >/dev/null && waiting=1
    [ "$waiting" -eq 0 ] || break
    sleep 0.05
  done
  [ "$waiting" -eq 1 ]
  # key set is waiting for the lock and checks the type inside it. The concurrent
  # writer finishes `provider set p --key env:P_API_KEY` and releases it.
  echo '{"version":1,"providers":{"p":{"transport":"http","base_url":"https://p.test/v1","key":{"type":"env","ref":"P_API_KEY"}}}}' >"$SHUNT_PROVIDERS_FILE"
  flock -u 9
  exec 9>&-
  wait "$bg" || true
  run "$SHUNT_MODELS_BIN" provider list
  refute_output --partial "$key"
  run jq -r '.providers.p.key.ref' "$SHUNT_PROVIDERS_FILE"
  refute_output "$key"
}

@test "key set and key status refuse a provider name outside the allowed charset" {
  local name action
  echo '{"version":1,"providers":{"p":{"transport":"http","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  for action in set status; do
    for name in 'a;rm -rf x' '$(id)'; do
      run bash -c "echo k | '$SHUNT_MODELS_BIN' key $action \"\$1\"" _ "$name"
      assert_failure
      assert_output --partial "invalid provider name"
    done
  done
}

@test "key set and key status on an existing entry with a rejected name say to edit providers.json" {
  local action
  echo '{"version":1,"providers":{"_old":{"transport":"http","key":{"type":"plaintext"}}}}' >"$SHUNT_PROVIDERS_FILE"
  for action in set status; do
    run bash -c "echo k | '$SHUNT_MODELS_BIN' key $action _old"
    assert_failure
    assert_output --partial '"_old"'
    assert_output --partial "edit providers.json"
  done
}
