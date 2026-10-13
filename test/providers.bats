load 'test_helper'

# scripts/lib/providers.sh is what shunt-key-dialog still sources. The rest of
# the provider logic is tested in test/py/test_providers.py and test_launcher_providers.py.

setup() {
  shunt_test_setup
  export SHUNT_PROVIDERS_FILE="$TEST_TMPDIR/providers.json"
  export SHUNT_PROC_VERSION_FILE="$TEST_TMPDIR/proc-version"
  echo "Linux version 6.1 (gcc)" >"$SHUNT_PROC_VERSION_FILE"
  source "$REPO_ROOT/scripts/lib/providers.sh"
}

teardown() {
  shunt_test_teardown
}

write_providers() {
  echo "$1" >"$SHUNT_PROVIDERS_FILE"
}

@test "missing providers.json means key type none" {
  run shunt_provider_key_type anything
  assert_success
  assert_output "none"
}

@test "key type is read from the provider entry" {
  write_providers '{"version":1,"providers":{"p":{"transport":"http","key":{"type":"plaintext"}}}}'
  run shunt_provider_key_type p
  assert_success
  assert_output "plaintext"
}

@test "an unusable providers file fails the key type lookup with its message" {
  write_providers '{"version":1,"providers":{"p":{"transport":"grpc"}}}'
  run shunt_provider_key_type p
  assert_failure
  assert_output --partial 'unknown transport "grpc"'
}

@test "plaintext warning mentions plain text" {
  run shunt_provider_plaintext_warning
  assert_output --partial "plain text"
}

@test "name_ok accepts plain names and refuses shell metacharacters and a trailing newline" {
  run shunt_provider_name_ok acme-1.x
  assert_success
  local name
  for name in 'a;rm -rf x' '$(id)' 'a b' '-x' $'ok\n'; do
    run shunt_provider_name_ok "$name"
    assert_failure
  done
}

@test "name_refuse explains an existing entry with a rejected name" {
  write_providers '{"providers":{"_old":{"transport":"http","key":{"type":"none"}}}}'
  run shunt_provider_name_refuse _old
  assert_output --partial '"_old"'
  assert_output --partial "edit providers.json"
}
