# Shared bats setup: loads bats-support/bats-assert and isolates each test
# into its own temp HOME/config/cache dir so nothing touches the real
# ~/.config or ~/.cache.

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load "$HELPER_DIR/test_helper/bats-support/load.bash"
load "$HELPER_DIR/test_helper/bats-assert/load.bash"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shunt_test_setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export SHUNT_MODELS_FILE="$TEST_TMPDIR/models.json"
  export SHUNT_AGENTS_DIR="$TEST_TMPDIR/agents"
  export SHUNT_OPENCODE_CONFIG_HOME="$TEST_TMPDIR/opencode"
  export SHUNT_ISOLATED_CONFIG_DIR="$TEST_TMPDIR/isolated-config"
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
