# Shared plumbing for delegating work to a custom model via the OpenCode CLI
# or an OpenAI-compatible HTTP API. Analogous to shunt's aika.sh, but shells
# out to `opencode run` (opencode.ai) instead of Spotify's Portal CLI, and
# targets user-configured OpenCode providers/agents instead of Spotify AiKA
# modes.
#
# Meant to be sourced by the evals and tests for the path defaults below and
# shunt_report_error. The shunt-* config scripts are Python launchers now.
# scripts/bulk-read and scripts/code-write are Python launchers and do not
# source it. The delegation itself (failover, transports, usage log) lives in
# scripts/py/shunt.

SHUNT_OPENCODE_BIN="${SHUNT_OPENCODE_BIN:-opencode}"
SHUNT_BULK_READER_AGENT="${SHUNT_BULK_READER_AGENT:-bulk-reader}"
SHUNT_OPENCODE_CONFIG_HOME="${SHUNT_OPENCODE_CONFIG_HOME:-$HOME/.config/opencode}"
SHUNT_ISOLATED_CONFIG_DIR="${SHUNT_ISOLATED_CONFIG_DIR:-$HOME/.cache/agent-model-shunt/opencode-config}"
SHUNT_AGENTS_DIR="${SHUNT_AGENTS_DIR:-$HOME/.config/agent-model-shunt/agents}"
SHUNT_DEBUG_LOG="${SHUNT_DEBUG_LOG:-}"
SHUNT_DEBUG_LOG_PATH="${SHUNT_DEBUG_LOG_PATH:-$HOME/.cache/agent-model-shunt/usage.jsonl}"

_SHUNT_OPENCODE_LIB_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=models.sh
source "$_SHUNT_OPENCODE_LIB_DIR/models.sh"
# shellcheck source=transport.sh
source "$_SHUNT_OPENCODE_LIB_DIR/transport.sh"
unset _SHUNT_OPENCODE_LIB_DIR

shunt_report_error() {
  echo "shunt: $1" >&2
  exit 1
}
