#!/usr/bin/env bash
# Shared preflight for the live eval scripts (sourced, not executed).
# The Python launchers (scripts/bulk-read, scripts/code-write) do their own
# preflight, so this only fails the eval early, before any scenario work.
# Same checks and message as the old shunt_preflight, minus `timeout`
# (the Python core enforces timeouts itself).

evals_preflight() {
  local bin="${SHUNT_OPENCODE_BIN:-opencode}"
  command -v "$bin" >/dev/null 2>&1 \
    || { echo "shunt: '$bin' not found in PATH. Install OpenCode (https://opencode.ai) or set SHUNT_OPENCODE_BIN." >&2; exit 1; }
  command -v jq >/dev/null 2>&1 \
    || { echo "shunt: 'jq' not found in PATH (the eval scripts use it for their result files)." >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 \
    || { echo "shunt: 'python3' not found in PATH." >&2; exit 1; }
}
