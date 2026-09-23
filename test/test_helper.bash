# Shared bats setup: loads bats-support/bats-assert and isolates each test
# into its own temp HOME/config/cache dir so nothing touches the real
# ~/.config or ~/.cache.

# Resolved through BATS_LIB_PATH (default includes /usr/lib/bats, where the
# bats/bats test image ships both libraries).
bats_load_library bats-support
bats_load_library bats-assert

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shunt_test_setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export SHUNT_MODELS_FILE="$TEST_TMPDIR/models.json"
  export SHUNT_AGENTS_DIR="$TEST_TMPDIR/agents"
  export SHUNT_OPENCODE_CONFIG_HOME="$TEST_TMPDIR/opencode"
  export SHUNT_ISOLATED_CONFIG_DIR="$TEST_TMPDIR/isolated-config"
  export SHUNT_BREAKER_STATE_FILE="$TEST_TMPDIR/breaker-state.json"
  export SHUNT_BREAKER_CONFIG_FILE="$TEST_TMPDIR/breaker-config.json"
  export SHUNT_SELF_FIX_CONFIG_FILE="$TEST_TMPDIR/self-fix-config.json"
  mkdir -p "$SHUNT_OPENCODE_CONFIG_HOME"
}

shunt_test_teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Writes a minimal opencode.json with a provider block for the given
# provider id (the part of a model id before the first "/").
shunt_write_provider() {
  local provider="$1"
  jq -n --arg p "$provider" '{provider: {($p): {models: {}}}}' \
    >"$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"
}
