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
# The optional fourth argument lists the kinds that call the delegate: a row
# whose `kind` is not among them gets delegate_model null. Rows without a
# `kind` (fidelity: every row asks the delegate) always get it. A line that
# is not JSON leaves the file as it was, with a warning and status 1.
evals_stamp_rows() {
  local file=$1 claude_model=$2 delegate_model=$3 delegate_kinds=${4:-} tmp
  tmp="$file.tmp.$$"
  if jq -c --arg c "$claude_model" --arg d "$delegate_model" --arg k "$delegate_kinds" '
      ($k | split(" ") | map(select(. != ""))) as $kinds
      | . + {claude_model: $c,
             delegate_model: (if $d == "" then null
                              elif (.kind == null) or ($kinds | length == 0) or (.kind as $x | $kinds | index($x)) then $d
                              else null end)}' \
      "$file" >"$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    echo "evals: could not add the model fields to $file (a line is not JSON); its rows stay as they were." >&2
    return 1
  fi
}
