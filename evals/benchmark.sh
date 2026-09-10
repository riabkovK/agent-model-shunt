#!/bin/bash
# Token-savings and latency benchmark for scripts/bulk-read.
#
# Measures, per scenario in evals/benchmarks.json:
#   - "without" tokens: chars/4 estimate of the raw file content Claude
#     would otherwise have read into its own context (same heuristic shunt
#     uses for its own benchmarks).
#   - "with" tokens: chars/4 estimate of the delegated model's answer,
#     which is what actually lands in Claude's context instead.
#   - latency: wall-clock time for the delegated `opencode run` call.
#   - custom-model usage: real input/output token counts opencode reports
#     for the delegated call. This is a separate cost paid by the custom
#     model, not by Claude; shown for transparency, not folded into the
#     savings percentage.
#
# Requires a reachable OpenCode provider. NOT part of the no-network
# evals/run.sh suite; run it separately once your provider is set up.
#
# Usage: evals/benchmark.sh

set -euo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EVALS_DIR/.." && pwd)"
BENCHMARKS="$EVALS_DIR/benchmarks.json"

# shellcheck source=../scripts/lib/opencode.sh
source "$REPO_ROOT/scripts/lib/opencode.sh"
shunt_preflight

token_estimate() {
  echo $(( (${#1} + 3) / 4 ))
}

count=$(jq '.benchmarks | length' "$BENCHMARKS")

total_without=0
total_with=0
total_ms=0
ok_count=0
rows=()

for ((i = 0; i < count; i++)); do
  name=$(jq -r ".benchmarks[$i].name" "$BENCHMARKS")
  question=$(jq -r ".benchmarks[$i].question" "$BENCHMARKS")

  paths=()
  corpus=""
  total_lines=0
  while IFS= read -r p; do
    full="$EVALS_DIR/$p"
    paths+=("$full")
    corpus="$corpus$(cat "$full")"
    lines=$(wc -l < "$full" | tr -d ' ')
    total_lines=$((total_lines + lines))
  done < <(jq -r ".benchmarks[$i].paths[]" "$BENCHMARKS")

  without_tokens=$(token_estimate "$corpus")

  echo "Running [$name] ($total_lines lines across ${#paths[@]} file(s))..." >&2

  stderr_file=$(mktemp)
  start_ms=$(date +%s%3N)
  if response=$("$REPO_ROOT/scripts/bulk-read" --question "$question" --paths "${paths[@]}" 2>"$stderr_file"); then
    end_ms=$(date +%s%3N)
    usage=$(grep -o 'usage:.*' "$stderr_file" | sed 's/^usage: //')
    with_tokens=$(token_estimate "$response")
    pct=0
    [ "$without_tokens" -gt 0 ] && pct=$(( (without_tokens - with_tokens) * 100 / without_tokens ))
    elapsed_ms=$((end_ms - start_ms))

    total_without=$((total_without + without_tokens))
    total_with=$((total_with + with_tokens))
    total_ms=$((total_ms + elapsed_ms))
    ok_count=$((ok_count + 1))

    rows+=("ok|$name|$total_lines|$without_tokens|$with_tokens|$pct|$elapsed_ms|$usage")
  else
    end_ms=$(date +%s%3N)
    elapsed_ms=$((end_ms - start_ms))
    error_line=$(tail -1 "$stderr_file")
    echo "  FAILED after ${elapsed_ms}ms: $error_line" >&2
    rows+=("fail|$name|$total_lines|$without_tokens|-|-|$elapsed_ms|$error_line")
  fi
  rm -f "$stderr_file"
done

echo ""
printf "%-22s %8s %14s %12s %8s %10s  %s\n" "Scenario" "Lines" "Without (est)" "With (est)" "Savings" "Latency" "Custom-model usage / error"
printf "%-22s %8s %14s %12s %8s %10s  %s\n" "----------------------" "--------" "--------------" "------------" "--------" "----------" "---------------------------"
for r in "${rows[@]}"; do
  IFS='|' read -r status name lines without with pct ms extra <<< "$r"
  if [ "$status" = "ok" ]; then
    printf "%-22s %8s %11s tk %9s tk %7s%% %9sms  %s\n" "$name" "$lines" "$without" "$with" "$pct" "$ms" "$extra"
  else
    printf "%-22s %8s %11s tk %12s %8s %9sms  %s\n" "$name" "$lines" "$without" "FAILED" "-" "$ms" "$extra"
  fi
done

echo ""
if [ "$ok_count" -eq 0 ]; then
  echo "All scenarios failed. Check that OpenCode, the 'bulk-reader' agent, and your provider are reachable (see README.md)."
  exit 1
fi

total_pct=0
[ "$total_without" -gt 0 ] && total_pct=$(( (total_without - total_with) * 100 / total_without ))
avg_ms=$((total_ms / ok_count))

printf "Total (%d/%d scenarios succeeded): %s tk -> %s tk (%s%% savings), avg latency %sms/call\n" \
  "$ok_count" "$count" "$total_without" "$total_with" "$total_pct" "$avg_ms"
echo ""
echo "Token estimate: chars/4 (same heuristic shunt uses), on the Claude side only."
echo "Latency is the added cost of a live opencode round-trip: weigh it against"
echo "the token savings for your own use case, especially for interactive,"
echo "back-and-forth work where round-trip latency matters more than tokens."
