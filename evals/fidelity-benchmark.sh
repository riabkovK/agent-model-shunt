#!/bin/bash
# Fidelity benchmark: does delegating a read to scripts/bulk-read (OpenCode)
# lose information or introduce hallucination, compared to Claude reading
# the same file(s) directly?
#
# evals/baseline-benchmark.sh measures cost/latency. This script instead
# measures answer *correctness*, using the ground-truth question set in
# evals/fidelity-questions.json (must_mention items extracted mechanically
# from evals/fixtures/echo/*.go, not written from memory).
#
# For each question, three answers are captured:
#   direct    Claude reads the file content directly (inlined in the
#             prompt) and answers. Represents the no-delegation baseline.
#   delegate  scripts/bulk-read's raw answer (the delegate model's own
#             output, never seen by Claude).
#   final     Claude answers the same question using ONLY the delegate's
#             raw answer above (not the file) - this is what a real user
#             actually sees when the PreToolUse hook blocks a direct read
#             and Claude falls back to bulk-read.
#
# Scoring is exact/structured, not LLM-judged: recall = fraction of
# ground_truth.must_mention items found as a case-insensitive substring of
# the answer. Hallucination is flagged when an item appears in `final` but
# not in `delegate` (the only source `final` had) - see fidelity-questions.json's
# hallucination_check note for the caveat this heuristic carries.
#
# Requires a reachable OpenCode provider (for the delegate side) and a
# logged-in `claude` CLI (for the direct/final sides). NOT part of the
# no-network evals/run.sh suite. Baseline (direct/final) calls hit the real
# Claude API and spend real money - run deliberately, not in a retry loop.
#
# Usage: evals/fidelity-benchmark.sh
#
# Env:
#   ITERATIONS              Repeats per question (default: 1). Total claude -p
#                            calls = ITERATIONS * questions * 2 (direct + final).
#   SHUNT_BASELINE_MODEL     Model alias for `claude -p --model` (default: sonnet).
#   SHUNT_BASELINE_TIMEOUT   Timeout in seconds per claude -p call (default: 300).

set -uo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EVALS_DIR/.." && pwd)"
QUESTIONS="$EVALS_DIR/fidelity-questions.json"
RESULTS_DIR="$EVALS_DIR/results"
RESULTS_JSONL="$RESULTS_DIR/fidelity-benchmark.jsonl"
SUMMARY_JSON="$RESULTS_DIR/fidelity-benchmark-summary.json"

SHUNT_BASELINE_MODEL="${SHUNT_BASELINE_MODEL:-sonnet}"
SHUNT_BASELINE_TIMEOUT="${SHUNT_BASELINE_TIMEOUT:-300}"
ITERATIONS="${ITERATIONS:-1}"

command -v claude >/dev/null 2>&1 || { echo "fidelity-benchmark: 'claude' not found in PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "fidelity-benchmark: 'jq' not found in PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "fidelity-benchmark: 'python3' not found in PATH (needed for aggregation)." >&2; exit 1; }

# shellcheck source=../scripts/lib/opencode.sh
source "$REPO_ROOT/scripts/lib/opencode.sh"
shunt_preflight

mkdir -p "$RESULTS_DIR"
: > "$RESULTS_JSONL"

count=$(jq '.questions | length' "$QUESTIONS")
total_cost_usd="0"
any_failed=0

# call_claude <prompt> -> sets LAST_ANSWER and LAST_COST (empty on failure)
call_claude() {
  local prompt="$1"
  LAST_ANSWER=""
  LAST_COST="0"

  local out status
  out=$(mktemp)
  status=0
  timeout "$SHUNT_BASELINE_TIMEOUT" claude -p --output-format json --model "$SHUNT_BASELINE_MODEL" \
    "$prompt" >"$out" 2>/dev/null || status=$?

  if [ "$status" -ne 0 ] || [ ! -s "$out" ]; then
    rm -f "$out"
    return 1
  fi

  LAST_ANSWER=$(jq -r '.result // empty' "$out")
  LAST_COST=$(jq -r '.total_cost_usd // 0' "$out")
  rm -f "$out"
  [ -n "$LAST_ANSWER" ]
}

# recall_of <must_mention_json_array> <answer_text> -> prints
# {"matched":[...],"unmatched":[...],"total":N}
recall_of() {
  local must_mention_json="$1" answer="$2"
  python3 - "$must_mention_json" "$answer" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
answer = sys.argv[2].lower()
matched = [i for i in items if i.lower() in answer]
unmatched = [i for i in items if i.lower() not in answer]
print(json.dumps({"matched": matched, "unmatched": unmatched, "total": len(items)}))
PY
}

for ((it = 1; it <= ITERATIONS; it++)); do
  for ((i = 0; i < count; i++)); do
    id=$(jq -r ".questions[$i].id" "$QUESTIONS")
    name=$(jq -r ".questions[$i].name" "$QUESTIONS")
    question=$(jq -r ".questions[$i].question" "$QUESTIONS")
    adversarial=$(jq -r ".questions[$i].adversarial" "$QUESTIONS")
    must_mention=$(jq -c ".questions[$i].ground_truth.must_mention" "$QUESTIONS")

    paths=()
    while IFS= read -r p; do
      paths+=("$EVALS_DIR/$p")
    done < <(jq -r ".questions[$i].paths[]" "$QUESTIONS")

    echo "[iter $it/$ITERATIONS][$name] direct..." >&2
    direct_prompt="$question"
    for p in "${paths[@]}"; do
      direct_prompt="$direct_prompt

=== $(basename "$p") ===
$(cat "$p")"
    done
    direct_prompt="$direct_prompt

Answer using only the content above. Do not use any tools."

    direct_answer="" direct_cost="0" direct_failed=0
    if call_claude "$direct_prompt"; then
      direct_answer="$LAST_ANSWER"
      direct_cost="$LAST_COST"
      total_cost_usd=$(awk -v a="$total_cost_usd" -v b="$direct_cost" 'BEGIN { printf "%.6f", a + b }')
    else
      echo "  direct FAILED" >&2
      direct_failed=1
      any_failed=1
    fi

    echo "[iter $it/$ITERATIONS][$name] delegate (bulk-read)..." >&2
    delegate_answer="" delegate_failed=0
    if delegate_answer=$("$REPO_ROOT/scripts/bulk-read" --question "$question" --paths "${paths[@]}" 2>/dev/null); then
      :
    else
      echo "  delegate FAILED" >&2
      delegate_failed=1
      any_failed=1
    fi

    final_answer="" final_cost="0" final_failed=0
    if [ "$delegate_failed" -eq 0 ]; then
      echo "[iter $it/$ITERATIONS][$name] final (Claude answers from delegate's text only)..." >&2
      final_prompt="$question

=== Answer from delegate model (you did not read the file yourself) ===
$delegate_answer

Answer the question using only the delegate's answer above. Do not use any tools."
      if call_claude "$final_prompt"; then
        final_answer="$LAST_ANSWER"
        final_cost="$LAST_COST"
        total_cost_usd=$(awk -v a="$total_cost_usd" -v b="$final_cost" 'BEGIN { printf "%.6f", a + b }')
      else
        echo "  final FAILED" >&2
        final_failed=1
        any_failed=1
      fi
    else
      final_failed=1
    fi

    direct_recall='{"matched":[],"unmatched":[],"total":0}'
    delegate_recall='{"matched":[],"unmatched":[],"total":0}'
    final_recall='{"matched":[],"unmatched":[],"total":0}'
    unsupported='[]'

    [ "$direct_failed" -eq 0 ] && direct_recall=$(recall_of "$must_mention" "$direct_answer")
    [ "$delegate_failed" -eq 0 ] && delegate_recall=$(recall_of "$must_mention" "$delegate_answer")
    if [ "$final_failed" -eq 0 ]; then
      final_recall=$(recall_of "$must_mention" "$final_answer")
      # unsupported = items matched in final but not matched in delegate's raw answer
      unsupported=$(python3 - "$final_recall" "$delegate_recall" <<'PY'
import json, sys
final = json.loads(sys.argv[1])
delegate = json.loads(sys.argv[2])
delegate_matched = set(delegate["matched"])
print(json.dumps([i for i in final["matched"] if i not in delegate_matched]))
PY
      )
    fi

    jq -n -c \
      --arg iter "$it" --argjson qid "$id" --arg name "$name" --argjson adversarial "$adversarial" \
      --argjson direct_failed "$direct_failed" --argjson delegate_failed "$delegate_failed" --argjson final_failed "$final_failed" \
      --argjson direct_recall "$direct_recall" --argjson delegate_recall "$delegate_recall" --argjson final_recall "$final_recall" \
      --argjson unsupported_claims "$unsupported" \
      --argjson direct_cost "${direct_cost:-0}" --argjson final_cost "${final_cost:-0}" \
      '{iteration: ($iter|tonumber), question_id: $qid, name: $name, adversarial: $adversarial,
        direct_failed: ($direct_failed==1), delegate_failed: ($delegate_failed==1), final_failed: ($final_failed==1),
        direct_recall: $direct_recall, delegate_recall: $delegate_recall, final_recall: $final_recall,
        unsupported_claims: $unsupported_claims, direct_cost_usd: $direct_cost, final_cost_usd: $final_cost}' \
      >>"$RESULTS_JSONL"
  done
done

echo "" >&2
printf "Total real Claude API cost for this run: \$%s\n" "$total_cost_usd" >&2
[ "$any_failed" -eq 1 ] && echo "One or more calls failed; see *_failed:true rows in $RESULTS_JSONL." >&2

echo ""
python3 "$EVALS_DIR/aggregate-fidelity-results.py" "$RESULTS_JSONL" "$SUMMARY_JSON"
