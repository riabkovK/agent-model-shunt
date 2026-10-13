# Shared plumbing for delegating work to a custom model via the OpenCode CLI
# or an OpenAI-compatible HTTP API. Analogous to shunt's aika.sh, but shells
# out to `opencode run` (opencode.ai) instead of Spotify's Portal CLI, and
# targets user-configured OpenCode providers/agents instead of Spotify AiKA
# modes.
#
# Meant to be sourced by the bats tests and the libraries that still need these wrappers
# (scripts/bulk-read and scripts/code-write are Python launchers now).
#
# Most of the work is Python now (scripts/py/shunt): failover.py runs the loop
# over the candidate models in one process (candidates, circuit breaker,
# transport, failure notes), usage_log.py reads the normalized response and
# appends to the debug usage log, opencode_cli.py builds the isolated OpenCode
# config. The functions below are the thin wrappers the scripts call, with the
# same stdout, stderr text and exit codes as before.

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
# shellcheck source=breaker.sh
source "$_SHUNT_OPENCODE_LIB_DIR/breaker.sh"
# shellcheck source=transport.sh
source "$_SHUNT_OPENCODE_LIB_DIR/transport.sh"
unset _SHUNT_OPENCODE_LIB_DIR

shunt_report_error() {
  echo "shunt: $1" >&2
  exit 1
}

# shunt_prepare_isolated_config <agent>
# Builds a minimal, isolated OpenCode config directory (XDG_CONFIG_HOME-style)
# containing only the named agent and the single provider its `model:`
# frontmatter references, owner-only (it copies the provider block, which holds
# credentials), and prints the isolated config root. `opencode run` otherwise
# loads the user's whole global config for every call (all skills, commands and
# MCP servers), which can inflate a small read from a few thousand prompt tokens
# to tens of thousands. The user's real config is never touched. The agent file
# is looked up in SHUNT_AGENTS_DIR, then in $SHUNT_OPENCODE_CONFIG_HOME/agents.
# Each agent gets its own subdirectory so two agents never share an
# opencode.json. Exits 1 with a `shunt:` line when the agent is not found or the
# config cannot be built. See opencode_cli.prepare_isolated_config.
shunt_prepare_isolated_config() {
  _shunt_oc_py opencode prepare-config -- "$1" || exit 1
}

# _shunt_note_failure <model-id> <try-invoke-status> [agent]
# Prints one stderr line saying why a candidate failed, for the statuses
# shunt_transport_invoke names (see failover.note_failure).
_shunt_note_failure() {
  _shunt_oc_py failover note-failure -- "$1" "$2" "${3:-}"
}

# shunt_invoke <agent> <question> [file...]
# Legacy single-agent path: one delegated call, fatal (exit 1 with a `shunt:`
# line) on any failure. Prints the path to the normalized response file. Used
# when no models.json registry exists yet (no breaker/failover to fall back on).
shunt_invoke() {
  local agent="$1" question="$2"
  shift 2
  _shunt_oc_py failover legacy -- "$agent" "$question" "$@" || exit
}

# shunt_invoke_with_failover <question> [file...]
# Delegates a bulk-read call. Falls back to the single legacy
# SHUNT_BULK_READER_AGENT unchanged (no breaker involved) when no models.json
# registry exists yet, otherwise runs the bulk-read role with no acceptance
# check. Sets SHUNT_INVOKE_OUT_FILE and SHUNT_INVOKE_AGENT_USED as
# shunt_invoke_role_with_failover does. Call it directly, never inside a
# command substitution.
shunt_invoke_with_failover() {
  local question="$1" out
  shift
  out=$(_shunt_oc_py failover bulk --legacy-agent "$SHUNT_BULK_READER_AGENT" -- "$question" "$@") || exit
  SHUNT_INVOKE_OUT_FILE="${out%%$'\n'*}"
  SHUNT_INVOKE_AGENT_USED="${out#*$'\n'}"
}

# shunt_invoke_role_with_failover <role> <agent-fn> <accept-fn|""> <question> [file...]
# Delegates a call, trying the candidate models in the shunt-owned models.json
# registry that have <role> (priority order, skipping any whose circuit
# breaker is open) and recording each attempt's outcome in the circuit breaker.
# The breaker key is the plain model id for bulk-read and "<id>#<role>" for any
# other role, so each role pauses a model on its own. A model that fails to run
# gets one "shunt: <id> failed: <reason>" line on stderr. A model that refuses
# the input as too large, whose key is rejected or that has a config problem is
# skipped without a breaker failure. When no model succeeds and at least one
# refused as oversize, the call ends with "no delegate model can take this
# input". <agent-fn> is shunt_models_agent_for (the default) or
# shunt_models_code_writer_agent_for, which picks the agent run for a model id.
# <accept-fn> must be empty: a role whose answers are judged by the caller
# (code-write) runs in Python (failover.run_role with an accept callback, see
# scripts/py/shunt/code_write.py). The whole loop is one Python process. Sets
# SHUNT_INVOKE_OUT_FILE to the output file path and SHUNT_INVOKE_AGENT_USED to
# the model id. Both are globals, not stdout: call it directly. Fatal only once
# every candidate has been tried and failed, or every candidate's breaker is
# open, or there is no candidate with the role.
shunt_invoke_role_with_failover() {
  local role="$1" agent_fn="$2" accept_fn="$3" question="$4" out kind=bulk
  shift 4
  [ -z "$accept_fn" ] || shunt_report_error "an accept function is not supported here (code-write runs in Python)."
  [ "$agent_fn" != shunt_models_code_writer_agent_for ] || kind=writer
  out=$(_shunt_oc_py failover run --role "$role" --agent-kind "$kind" -- "$question" "$@") || exit
  SHUNT_INVOKE_OUT_FILE="${out%%$'\n'*}"
  SHUNT_INVOKE_AGENT_USED="${out#*$'\n'}"
}

# shunt_extract_text <response-file>
# Prints the answer text of a normalized response (see transport.sh). Exits 1
# when there is none.
shunt_extract_text() {
  _shunt_oc_py usage text -- "$1" || exit 1
}

# shunt_extract_usage <response-file>
# Prints a one-line "input=N output=N cost=N" usage summary, or nothing if unavailable.
shunt_extract_usage() {
  _shunt_oc_py usage summary -- "$1" || true
}

# shunt_extract_finish_reason <response-file>
# Prints the finish reason of a normalized response ("stop" for a normal end of
# the answer, "length" when it was cut off by the token limit), or nothing when
# the transport reported none. shunt_extract_usage does not expose it, so a
# caller that must know whether the answer is complete asks here.
shunt_extract_finish_reason() {
  _shunt_oc_py usage finish-reason -- "$1" || true
}

# shunt_log_usage <agent> <response-file> <question> <file...>
# Appends a bulk-read entry to SHUNT_DEBUG_LOG_PATH: which delegate call this
# was, its real usage (from <response-file>, the same normalized response
# shunt_extract_usage reads), and a chars/4 estimate (evals/benchmark.sh's own
# documented heuristic) of the tokens Claude's context avoided by not reading
# <file...> directly. Never fails the caller: logging errors are swallowed
# since this is a debug aid, not part of the delegation path.
shunt_log_usage() {
  local agent="$1" resp="$2" question="$3"
  shift 3
  _shunt_oc_py usage log-bulk -- "$agent" "$resp" "$question" "$@" || true
}

# shunt_log_code_write <agent> <response-file> <spec> <generated-bytes> <file...>
# Logs a code-write call. What delegating saves here is Claude's OUTPUT, the
# file it did not have to write, so avoided_tokens_estimate (the input-side
# figure of bulk-read) stays 0 and avoided_output_tokens_estimate is a chars/4
# estimate over <generated-bytes>. <file...> are the attached inputs, logged
# for reference only. Never fails the caller.
shunt_log_code_write() {
  local agent="$1" resp="$2" spec="$3" generated_bytes="$4"
  shift 4
  _shunt_oc_py usage log-code-write -- "$agent" "$resp" "$spec" "$generated_bytes" "$@" || true
}
