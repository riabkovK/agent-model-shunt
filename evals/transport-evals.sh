#!/bin/bash
# End-to-end eval: actually calls scripts/bulk-read, which shells out to a
# live `opencode run` against your configured OpenCode agent/provider.
#
# Unlike run.sh (hook logic only, no network), this suite requires a
# reachable OpenCode provider and is NOT run as part of CI by default.
#
# Usage: evals/transport-evals.sh

set -euo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EVALS_DIR/.." && pwd)"

echo "== transport eval: scripts/bulk-read against a live OpenCode agent =="
echo "This requires: opencode on PATH, a configured provider, and the"
echo "'bulk-reader' agent (see README.md setup). It will time out after"
echo "\${SHUNT_TIMEOUT_SECONDS:-120}s if the provider is unreachable."
echo

question="What is the topic of line 1 in this file? Answer in one short sentence."
fixture="$EVALS_DIR/fixtures/small.txt"

if ! answer=$("$REPO_ROOT/scripts/bulk-read" --question "$question" --paths "$fixture"); then
  echo "FAIL: scripts/bulk-read exited non-zero (see stderr above for details)."
  exit 1
fi

if [ -z "$answer" ]; then
  echo "FAIL: scripts/bulk-read produced an empty answer."
  exit 1
fi

echo "PASS: scripts/bulk-read returned a non-empty answer:"
echo "---"
echo "$answer"
echo "---"
