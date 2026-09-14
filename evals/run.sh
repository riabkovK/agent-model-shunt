#!/bin/bash
# Runs the hook eval suites (check-file-size, check-bash-read) against
# evals/hook-evals.json and evals/bash-hook-evals.json.
#
# Usage: evals/run.sh

set -euo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EVALS_DIR/.." && pwd)"

pass=0
fail=0

run_suite() {
  local suite_file="$1"
  local hook_path="$2"
  local input_key="$3" # "tool_input" wrapper key expected by the hook

  local count
  count=$(jq 'length' "$suite_file")

  local i
  for ((i = 0; i < count; i++)); do
    local case_json name expected actual
    case_json=$(jq -c ".[$i]" "$suite_file")
    name=$(echo "$case_json" | jq -r '.name')
    expected=$(echo "$case_json" | jq -r '.expected_decision')

    local payload
    payload=$(echo "$case_json" | jq -c "{$input_key: .tool_input}")

    actual=$(cd "$REPO_ROOT" && echo "$payload" | "$hook_path" | jq -r '.decision')

    if [ "$actual" = "$expected" ]; then
      echo "PASS: $name"
      pass=$((pass + 1))
    else
      echo "FAIL: $name (expected=$expected actual=$actual)"
      fail=$((fail + 1))
    fi
  done
}

echo "== check-file-size =="
run_suite "$EVALS_DIR/hook-evals.json" "$REPO_ROOT/hooks/check-file-size" "tool_input"

echo
echo "== check-bash-read =="
run_suite "$EVALS_DIR/bash-hook-evals.json" "$REPO_ROOT/hooks/check-bash-read" "tool_input"

echo
echo "== SHUNT_HOOKS_DISABLED override =="

check_disabled_override() {
  local name="$1" hook_path="$2" payload="$3"
  local actual
  actual=$(cd "$REPO_ROOT" && echo "$payload" | SHUNT_HOOKS_DISABLED=1 "$hook_path" | jq -r '.decision')
  if [ "$actual" = "allow" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name (expected=allow actual=$actual)"
    fail=$((fail + 1))
  fi
}

check_disabled_override \
  "check-file-size allows big file when SHUNT_HOOKS_DISABLED=1" \
  "$REPO_ROOT/hooks/check-file-size" \
  '{"tool_input": {"file_path": "evals/fixtures/big.txt"}}'

check_disabled_override \
  "check-bash-read allows cat on big file when SHUNT_HOOKS_DISABLED=1" \
  "$REPO_ROOT/hooks/check-bash-read" \
  '{"tool_input": {"command": "cat evals/fixtures/big.txt"}}'

echo
echo "== Summary: $pass passed, $fail failed =="

[ "$fail" -eq 0 ]
