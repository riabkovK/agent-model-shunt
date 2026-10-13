# Shared plumbing for delegating work to a custom model via the OpenCode CLI
# or an OpenAI-compatible HTTP API. Analogous to shunt's aika.sh, but shells
# out to `opencode run` (opencode.ai) instead of Spotify's Portal CLI, and
# targets user-configured OpenCode providers/agents instead of Spotify AiKA
# modes.
#
# Meant to be sourced by scripts/bulk-read and scripts/code-write.
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

shunt_preflight() {
  command -v "$SHUNT_OPENCODE_BIN" >/dev/null 2>&1 \
    || shunt_report_error "'$SHUNT_OPENCODE_BIN' not found in PATH. Install OpenCode (https://opencode.ai) or set SHUNT_OPENCODE_BIN."
  command -v jq >/dev/null 2>&1 \
    || shunt_report_error "'jq' not found in PATH. Install jq to parse OpenCode's JSON output."
  command -v timeout >/dev/null 2>&1 \
    || shunt_report_error "'timeout' not found in PATH (part of GNU coreutils)."
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

# _shunt_breaker_record <success|failure> <key>
# Records an attempt outcome in the circuit breaker, for the verdict of an
# accept function. A breaker write failure (corrupt or unwritable state file)
# is non-fatal: the breaker is only an optimisation, so it must not kill a call
# whose paid generation already happened or skip the failover to the next
# model. Prints one stderr warning with the state file path only.
_shunt_breaker_record() {
  local outcome="$1" key="$2"
  if ! "shunt_breaker_record_$outcome" "$key"; then
    echo "shunt: warning: could not update the circuit breaker state ($SHUNT_BREAKER_STATE_FILE)" >&2
  fi
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
# <accept-fn>, when non-empty, is called with the output file and the model id
# and judges the answer, so a role can count an unusable answer as a model
# failure:
#   0  accept: the model succeeded (breaker success), the output is kept
#   1  reject: a model failure (breaker failure), try the next model
#   2  abort: an environment problem that is not the model's fault, the call
#      ends fatally and the breaker is left alone
# It runs in this shell, so it may set globals. Without one, the whole loop is
# one Python process. With one, Python runs the loop up to the first answer and
# this function judges it, then asks for the next candidate. Sets
# SHUNT_INVOKE_OUT_FILE to the accepted output file path and
# SHUNT_INVOKE_AGENT_USED to the model id. Both are globals, not stdout: call
# it directly. Fatal only once every candidate has been tried and failed, or
# every candidate's breaker is open, or there is no candidate with the role.
shunt_invoke_role_with_failover() {
  local role="$1" agent_fn="$2" accept_fn="$3" question="$4"
  shift 4
  local kind=bulk out out_file id index key verdict start=0 oversize=0
  [ "$agent_fn" != shunt_models_code_writer_agent_for ] || kind=writer

  if [ -z "$accept_fn" ]; then
    out=$(_shunt_oc_py failover run --role "$role" --agent-kind "$kind" -- "$question" "$@") || exit
    SHUNT_INVOKE_OUT_FILE="${out%%$'\n'*}"
    SHUNT_INVOKE_AGENT_USED="${out#*$'\n'}"
    return 0
  fi

  while :; do
    out=$(_shunt_oc_py failover run --role "$role" --agent-kind "$kind" --external-accept \
      --start "$start" --oversize "$oversize" -- "$question" "$@") || exit
    { IFS= read -r out_file; IFS= read -r id; IFS= read -r index; IFS= read -r oversize; } <<<"$out"
    key=$(shunt_breaker_key "$id" "$role")
    verdict=0
    "$accept_fn" "$out_file" "$id" || verdict=$?
    case "$verdict" in
      0)
        _shunt_breaker_record success "$key"
        SHUNT_INVOKE_AGENT_USED="$id"
        SHUNT_INVOKE_OUT_FILE="$out_file"
        return 0
        ;;
      1) rm -f "$out_file" ;;
      *)
        rm -f "$out_file"
        exit 1
        ;;
    esac
    _shunt_breaker_record failure "$key"
    start=$((index + 1))
  done
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

# shunt_debug_log_enabled
# Returns success (0) if SHUNT_DEBUG_LOG is truthy, matching the same
# accepted values as SHUNT_HOOKS_DISABLED.
shunt_debug_log_enabled() {
  case "${SHUNT_DEBUG_LOG:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
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
