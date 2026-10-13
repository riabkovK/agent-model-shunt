# Shared bats setup: loads bats-support/bats-assert and isolates each test
# into its own temp HOME/config/cache dir so nothing touches the real
# ~/.config or ~/.cache.

# Resolved through BATS_LIB_PATH (default includes /usr/lib/bats, where the
# bats/bats test image ships both libraries).
bats_load_library bats-support
bats_load_library bats-assert

REPO_ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shunt_test_setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export SHUNT_MODELS_FILE="$TEST_TMPDIR/models.json"
  export SHUNT_AGENTS_DIR="$TEST_TMPDIR/agents"
  export SHUNT_OPENCODE_CONFIG_HOME="$TEST_TMPDIR/opencode"
  export SHUNT_ISOLATED_CONFIG_DIR="$TEST_TMPDIR/isolated-config"
  export SHUNT_BREAKER_STATE_FILE="$TEST_TMPDIR/breaker-state.json"
  export SHUNT_BREAKER_CONFIG_FILE="$TEST_TMPDIR/breaker-config.json"
  export SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE="$TEST_TMPDIR/code-write-self-fix-config.json"
  # Keep HOME, XDG and TMPDIR inside the temp dir so no test can reach the
  # real user config, state, cache or temp files.
  export HOME="$TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$TEST_TMPDIR/xdg-config"
  export XDG_STATE_HOME="$TEST_TMPDIR/xdg-state"
  export XDG_CACHE_HOME="$TEST_TMPDIR/xdg-cache"
  export SHUNT_ORCHESTRATOR_DIR="$TEST_TMPDIR/orchestrator.d"
  export TMPDIR="$TEST_TMPDIR/tmp"
  mkdir -p "$SHUNT_OPENCODE_CONFIG_HOME" "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
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

# start_http_server <routes-dir> [extra httpserver.py args, e.g. --sent PREFIX]
# Starts test/py/httpserver.py in the background on a free 127.0.0.1 port, serving
# route files from <routes-dir> (see the header of that file). Sets HTTP_PORT,
# HTTP_LOG (one JSON line per request) and HTTP_PID. Pair it with stop_http_server
# in teardown. Replaces the fake curl of the older tests.
start_http_server() {
  local port_file="$TEST_TMPDIR/http-port" i
  HTTP_LOG="$TEST_TMPDIR/http-log"
  rm -f "$port_file" "$HTTP_LOG"
  # 3>&- so the server does not hold bats' result pipe open after the test.
  python3 -B "$REPO_ROOT/test/py/httpserver.py" --routes "$1" --port-file "$port_file" --log "$HTTP_LOG" "${@:2}" \
    >/dev/null 2>&1 3>&- &
  HTTP_PID=$!
  for i in $(seq 1 200); do
    [ -s "$port_file" ] && break
    sleep 0.05
  done
  HTTP_PORT=$(cat "$port_file")
  # Requests to the local server never go through a proxy of the host.
  export no_proxy="127.0.0.1${no_proxy:+,$no_proxy}" NO_PROXY="127.0.0.1${NO_PROXY:+,$NO_PROXY}"
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
}

# stop_http_server: kills the server started by start_http_server, if any.
stop_http_server() {
  if [ -n "${HTTP_PID:-}" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    HTTP_PID=""
  fi
}
