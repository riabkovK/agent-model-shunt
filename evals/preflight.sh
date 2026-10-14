#!/usr/bin/env bash
# Shared helpers for the live eval scripts (sourced, not executed).
# The Python launchers (scripts/bulk-read, scripts/code-write) do their own
# preflight, including the `opencode` binary check for providers on the
# opencode transport, so this only fails the eval early, before any scenario
# work, on what the eval scripts themselves need.

evals_preflight() {
  command -v jq >/dev/null 2>&1 \
    || { echo "shunt: 'jq' not found in PATH (the eval scripts use it for their result files)." >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 \
    || { echo "shunt: 'python3' not found in PATH." >&2; exit 1; }
}

# Prints the registry's first choice for a role (bulk-read or code-write)
# without its provider prefix (a provider name is often a private host alias,
# and results files get committed), or nothing when there is none. Read it
# before the first call: failover can answer from a later model, so this is
# the model the run was aimed at.
evals_first_choice() {
  local prefix="first choice"
  [ "$1" = code-write ] && prefix="code-write first choice"
  "$REPO_ROOT/scripts/shunt-models" status 2>/dev/null \
    | sed -n "s/^shunt: $prefix: [^/]*\///p" | head -n 1
}

# Adds claude_model and delegate_model to every row of a results file, so the
# file alone says what it measured. An empty delegate model is stored as null.
evals_stamp_rows() {
  local file=$1 claude_model=$2 delegate_model=$3 tmp
  tmp="$file.tmp.$$"
  jq -c --arg c "$claude_model" --arg d "$delegate_model" \
    '. + {claude_model: $c, delegate_model: (if $d == "" then null else $d end)}' \
    "$file" >"$tmp" && mv "$tmp" "$file"
}
