# Shared plumbing for delegating work to a custom model via the OpenCode CLI.
# Analogous to shunt's aika.sh, but shells out to `opencode run` (opencode.ai)
# instead of Spotify's Portal CLI, and targets user-configured OpenCode
# providers/agents instead of Spotify AiKA modes.
#
# Meant to be sourced by scripts/bulk-read and scripts/code-write.

SHUNT_OPENCODE_BIN="${SHUNT_OPENCODE_BIN:-opencode}"
SHUNT_BULK_READER_AGENT="${SHUNT_BULK_READER_AGENT:-bulk-reader}"
SHUNT_OPENCODE_CONFIG_HOME="${SHUNT_OPENCODE_CONFIG_HOME:-$HOME/.config/opencode}"
SHUNT_ISOLATED_CONFIG_DIR="${SHUNT_ISOLATED_CONFIG_DIR:-$HOME/.cache/agent-model-shunt/opencode-config}"
SHUNT_AGENTS_DIR="${SHUNT_AGENTS_DIR:-$HOME/.config/agent-model-shunt/agents}"
SHUNT_DEBUG_LOG="${SHUNT_DEBUG_LOG:-}"
SHUNT_DEBUG_LOG_PATH="${SHUNT_DEBUG_LOG_PATH:-$HOME/.cache/agent-model-shunt/usage.jsonl}"

_SHUNT_OPENCODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

shunt_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/shunt-opencode.XXXXXX"
}

# shunt_prepare_isolated_config <agent>
# Builds a minimal, isolated OpenCode config directory (XDG_CONFIG_HOME-style)
# containing only the named agent and the single provider its `model:`
# frontmatter references. `opencode run` otherwise always loads the user's
# *entire* global ~/.config/opencode config for every call: all installed
# skills, commands, and MCP servers get attached regardless of the agent's
# own `tools:` restrictions, which can inflate a single small-file read from
# a few thousand prompt tokens to tens of thousands. Isolating the config
# fixes that without ever touching the user's real config. Prints the
# isolated config root to stdout.
#
# The agent file is looked up first in SHUNT_AGENTS_DIR (shunt-owned agents
# materialized by scripts/shunt-models), then falls back to
# $SHUNT_OPENCODE_CONFIG_HOME/agents (the legacy hand-written single-agent
# path, e.g. ~/.config/opencode/agents/bulk-reader.md).
#
# Each agent gets its own subdirectory under SHUNT_ISOLATED_CONFIG_DIR so
# that isolated configs for two different agents (e.g. two delegate models
# tried back to back) never share or clobber the same opencode.json.
shunt_prepare_isolated_config() {
  local agent="$1"

  local agent_file="$SHUNT_AGENTS_DIR/$agent.md"
  if [ ! -f "$agent_file" ]; then
    agent_file="$SHUNT_OPENCODE_CONFIG_HOME/agents/$agent.md"
  fi

  local iso_root="$SHUNT_ISOLATED_CONFIG_DIR/$agent"
  local iso_opencode="$iso_root/opencode"

  [ -f "$agent_file" ] \
    || shunt_report_error "OpenCode agent '$agent' not found in $SHUNT_AGENTS_DIR or $SHUNT_OPENCODE_CONFIG_HOME/agents. See README's Setup section."

  # The isolated opencode.json is a copy of the user's provider block, which
  # holds credentials: keep it and its directories owner-only. umask 077 covers
  # what this creates, and the chmods tighten what an older run left at 0644.
  # The caller's umask is restored before returning.
  local old_umask
  old_umask=$(umask)
  umask 077
  mkdir -p "$iso_opencode/agents"
  chmod 700 "$iso_root" "$iso_opencode" "$iso_opencode/agents"
  cp "$agent_file" "$iso_opencode/agents/$agent.md"

  local provider iso_json="$iso_opencode/opencode.json"
  provider=$(awk -F'[/: ]+' '/^model:/{print $2; exit}' "$agent_file")

  # Truncating an existing file keeps its mode, so tighten it before the write.
  [ ! -e "$iso_json" ] || chmod 600 "$iso_json"
  if [ -n "$provider" ] && [ -f "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json" ]; then
    jq --arg p "$provider" '{provider: {($p): .provider[$p]}}' \
      "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json" >"$iso_json" \
      || shunt_report_error "failed to build isolated OpenCode config from $SHUNT_OPENCODE_CONFIG_HOME/opencode.json."
  else
    echo '{}' >"$iso_json"
  fi
  umask "$old_umask"

  echo "$iso_root"
}

# shunt_try_invoke <agent> <question> [file...]
# Runs one delegated call through the transport layer (see transport.sh) and
# prints the path to a temp file holding the normalized response. Unlike
# shunt_invoke, never exits the process on failure (agent not found,
# transport error, timeout, empty output): returns non-zero (see the
# SHUNT_TRY_INVOKE_* statuses in transport.sh) and cleans up after itself, so
# shunt_invoke_with_failover can try the next candidate model instead of the
# whole delegated call dying on one bad model.
shunt_try_invoke() {
  shunt_transport_invoke "$@"
}

# _shunt_note_failure <model-id> <try-invoke-status> [agent]
# Prints one stderr line saying why a candidate failed, for the statuses
# shunt_try_invoke names. A generic ERROR names the agent's transport ("opencode
# error", "HTTP request error"), "request error" when the agent is not given or
# its transport cannot be looked up. Control characters are stripped from the
# id so a hand-edited registry cannot inject terminal escapes. Prints nothing
# for status 1 (the agent could not be prepared, already reported).
_shunt_note_failure() {
  local id reason
  id=$(printf '%s' "$1" | tr -d '[:cntrl:]')
  case "$2" in
    "$SHUNT_TRY_INVOKE_TIMEOUT") reason="timed out after ${SHUNT_TIMEOUT_SECONDS}s" ;;
    "$SHUNT_TRY_INVOKE_DEADLINE") reason="total deadline reached (SHUNT_TOTAL_TIMEOUT_SECONDS)" ;;
    "$SHUNT_TRY_INVOKE_ERROR")
      case "$( [ -z "${3:-}" ] || shunt_transport_for_agent "$3" 2>/dev/null)" in
        opencode) reason="opencode error" ;;
        http) reason="HTTP request error" ;;
        *) reason="request error" ;;
      esac
      ;;
    "$SHUNT_TRY_INVOKE_EMPTY") reason="empty output" ;;
    "$SHUNT_TRY_INVOKE_AUTH") reason="auth failed" ;;
    "$SHUNT_TRY_INVOKE_OVERSIZE") reason="input too large for this model" ;;
    "$SHUNT_TRY_INVOKE_CONFIG") reason="config problem (see above), skipped" ;;
    *) return 0 ;;
  esac
  echo "shunt: $id failed: $reason" >&2
}

# shunt_invoke <agent> <question> [file...]
# Legacy single-agent path: same call as shunt_try_invoke, but fatal (via
# shunt_report_error) on any failure. Used directly when no models.json
# registry exists yet (no breaker/failover to fall back on), and internally
# by shunt_invoke_with_failover for that same legacy case.
shunt_invoke() {
  local agent="$1" question="$2"
  shift 2
  local out status=0
  out=$(shunt_try_invoke "$agent" "$question" "$@") || status=$?
  if [ "$status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]; then
    shunt_report_error "no delegate model can take this input (too large for agent '$agent'). Read the file directly instead, in sections with offset/limit."
  elif [ "$status" -eq "$SHUNT_TRY_INVOKE_CONFIG" ]; then
    shunt_report_error "the model for agent '$agent' has a config problem (explained above), nothing was sent."
  elif [ "$status" -eq 1 ]; then
    shunt_report_error "agent '$agent' could not be run: it is not prepared, has no model in the registry, or its transport is unknown."
  elif [ "$status" -ne 0 ]; then
    if [ "$(shunt_transport_for_agent "$agent" 2>/dev/null)" = http ]; then
      _shunt_note_failure "$agent" "$status" "$agent"
      shunt_report_error "the HTTP request for agent '$agent' failed (reason above)."
    fi
    shunt_report_error "opencode run failed for agent '$agent' (not found, timed out after ${SHUNT_TIMEOUT_SECONDS}s, exited non-zero, or produced no output)."
  fi
  echo "$out"
}

# shunt_invoke_with_failover <question> [file...]
# Delegates a bulk-read call. Falls back to the single legacy
# SHUNT_BULK_READER_AGENT unchanged (no breaker involved) when no models.json
# registry exists yet, otherwise runs shunt_invoke_role_with_failover for the
# bulk-read role with no acceptance check. Sets SHUNT_INVOKE_OUT_FILE and
# SHUNT_INVOKE_AGENT_USED as that function does. Call it directly, never
# inside a command substitution.
shunt_invoke_with_failover() {
  local question="$1"
  shift
  local files=("$@")

  if ! shunt_models_available; then
    SHUNT_INVOKE_OUT_FILE=$(shunt_invoke "$SHUNT_BULK_READER_AGENT" "$question" ${files[@]+"${files[@]}"})
    SHUNT_INVOKE_AGENT_USED="$SHUNT_BULK_READER_AGENT"
    return 0
  fi

  # The role failover looks the candidates up quietly (its callers do their own
  # lookup first), so this is where an unknown `active` model gets reported.
  shunt_models_candidates bulk-read >/dev/null || true
  shunt_invoke_role_with_failover bulk-read shunt_models_agent_for "" "$question" ${files[@]+"${files[@]}"}
}

# _shunt_breaker_record <success|failure> <key>
# Records an attempt outcome in the circuit breaker. A breaker write failure
# (corrupt or unwritable state file) is non-fatal: the breaker is only an
# optimisation, so it must not kill a call whose paid generation already
# happened or skip the failover to the next model. Prints one stderr warning
# with the state file path only.
_shunt_breaker_record() {
  local outcome="$1" key="$2"
  if ! "shunt_breaker_record_$outcome" "$key"; then
    echo "shunt: warning: could not update the circuit breaker state ($SHUNT_BREAKER_STATE_FILE)" >&2
  fi
}

# shunt_invoke_role_with_failover <role> <agent-fn> <accept-fn|""> <question> [file...]
# Delegates a call, trying the candidate models in the shunt-owned models.json
# registry that have <role> (priority order, skipping any whose circuit
# breaker is open) and recording each attempt's outcome via
# shunt_breaker_record_success/_failure. The breaker key is the plain model id
# for bulk-read and "<id>#<role>" for any other role (shunt_breaker_key), so
# each role pauses a model on its own. A model that fails to run (timeout,
# opencode error, empty output) gets one "shunt: <id> failed: <reason>" line
# on stderr. A model that refuses the input as too large (OVERSIZE), whose
# key is rejected (AUTH) or that has a config problem (CONFIG) is skipped
# without a breaker failure. When no model
# succeeds and at least one refused as oversize, the call ends with "no
# delegate model can take this input" (see _shunt_report_no_delegate).
# <agent-fn> is called with a model id
# and prints the agent to run for it. <accept-fn>, when non-empty, is called
# with the output file and the model id and judges the answer, so a role can
# count an unusable answer as a model failure:
#   0  accept: the model succeeded (breaker success), the output is kept
#   1  reject: a model failure (breaker failure), try the next model
#   2  abort: an environment problem that is not the model's fault, the call
#      ends fatally and the breaker is left alone
# The function prints its own reason for a 1 or 2 if it wants one. It runs in
# this shell, so it may set globals. Sets SHUNT_INVOKE_OUT_FILE to the
# accepted output file path and SHUNT_INVOKE_AGENT_USED to the model id. Both
# are globals, not stdout: a caller that captured stdout with $(...) would run
# this in a subshell and lose them, so call it directly. Fatal only once every
# candidate has been tried and failed, or every candidate's breaker is open,
# or there is no candidate with the role.
shunt_invoke_role_with_failover() {
  local role="$1" agent_fn="$2" accept_fn="$3" question="$4"
  shift 4
  local files=("$@")

  # Quiet: the caller has already run its own shunt_models_candidates lookup
  # (a preflight, or shunt_invoke_with_failover), which reports an `active`
  # model missing from the registry. Printing it here too would say it twice.
  local candidates
  candidates=$(shunt_models_candidates "$role" quiet)
  if [ -z "$candidates" ]; then
    local hint=" Add or enable a model with that role using scripts/shunt-models."
    [ "$role" != "bulk-read" ] || hint=" Read the file directly instead, or add/enable a model with scripts/shunt-models."
    shunt_report_error "no enabled delegate models with the $role role in the registry at $(shunt_models_file).$hint"
  fi

  local id key agent out verdict try_status tried_any="" oversize=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    key=$(shunt_breaker_key "$id" "$role")
    shunt_breaker_is_open "$key" && continue
    tried_any=1
    agent=$("$agent_fn" "$id")
    try_status=0
    out=$(shunt_try_invoke "$agent" "$question" ${files[@]+"${files[@]}"}) || try_status=$?
    if [ "$try_status" -eq 0 ]; then
      verdict=0
      [ -z "$accept_fn" ] || "$accept_fn" "$out" "$id" || verdict=$?
      case "$verdict" in
        0)
          _shunt_breaker_record success "$key"
          SHUNT_INVOKE_AGENT_USED="$id"
          SHUNT_INVOKE_OUT_FILE="$out"
          return 0
          ;;
        1) rm -f "$out" ;;
        *)
          rm -f "$out"
          exit 1
          ;;
      esac
    else
      _shunt_note_failure "$id" "$try_status" "$agent"
      # A rejected key, a config problem or an input too large for the model says
      # nothing about the model: try the next candidate without counting a breaker failure.
      [ "$try_status" -ne "$SHUNT_TRY_INVOKE_AUTH" ] || continue
      [ "$try_status" -ne "$SHUNT_TRY_INVOKE_CONFIG" ] || continue
      if [ "$try_status" -eq "$SHUNT_TRY_INVOKE_OVERSIZE" ]; then
        oversize=$(( oversize + 1 ))
        continue
      fi
    fi
    _shunt_breaker_record failure "$key"
  done <<<"$candidates"

  if [ -z "$tried_any" ]; then
    shunt_report_error "every delegate model in the registry is currently paused (circuit breaker open); no candidates available."
  fi
  [ "$oversize" -eq 0 ] || _shunt_report_no_delegate "$role" "$oversize"
  shunt_report_error "all delegate models in the registry failed for this call."
}

# _shunt_report_no_delegate <role> <oversize-count>
# Ends a call in which no candidate took the input and at least one refused it
# as too large. For bulk-read this is the "Claude reads it itself" outcome: the
# message tells Claude to read the file directly, in offset/limit sections,
# which the check-file-size hook always lets through.
_shunt_report_no_delegate() {
  local hint=""
  [ "$1" != "bulk-read" ] || hint=" Read the file directly instead, in sections with offset/limit."
  shunt_report_error "no delegate model can take this input ($2 refused it as too large, the others failed or are paused).$hint"
}

# shunt_extract_text <response-file>
# Prints the answer text of a normalized response (see transport.sh).
shunt_extract_text() {
  local resp="$1"
  local text
  text=$(jq -r '.text // empty' "$resp" 2>/dev/null || true)

  if [ -z "$text" ]; then
    shunt_report_error "could not extract assistant text from the delegate response (normalized response kept at $resp for inspection)."
  fi

  echo "$text"
}

# shunt_extract_usage <response-file>
# Prints a one-line "input=N output=N cost=N" usage summary, or nothing if unavailable.
shunt_extract_usage() {
  local resp="$1"
  jq -r '
    if .usage == null then empty else
    "input=" + (.usage.input // 0 | tostring) +
    " output=" + (.usage.output // 0 | tostring) +
    " cost=" + (.cost // 0 | tostring)
    end
  ' "$resp" 2>/dev/null || true
}

# shunt_extract_finish_reason <response-file>
# Prints the finish reason of a normalized response ("stop" for a normal end of
# the answer, "length" when it was cut off by the token limit), or nothing when
# the transport reported none. shunt_extract_usage does not expose it, so a
# caller that must know whether the answer is complete asks here.
shunt_extract_finish_reason() {
  local resp="$1"
  jq -r '.finish_reason // empty' "$resp" 2>/dev/null || true
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

# _shunt_log_files_json <file...>
# Prints a JSON array of {path, lines, bytes}, one entry per readable file.
_shunt_log_files_json() {
  local files_json="[]" f bytes lines
  for f in "$@"; do
    bytes=$(wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0)
    lines=$(wc -l <"$f" 2>/dev/null | tr -d ' ' || echo 0)
    files_json=$(echo "$files_json" | jq -c --arg p "$f" --argjson b "$bytes" --argjson l "$lines" \
      '. + [{path: $p, lines: $l, bytes: $b}]')
  done
  echo "$files_json"
}

# _shunt_log_append <agent> <response-file> <question> <files-json> <avoided> <extra-json>
# Appends one JSON line to SHUNT_DEBUG_LOG_PATH: the fields every entry has
# (timestamp, agent, files, question_chars, the delegate's real usage read
# from <response-file>, avoided_tokens_estimate) merged with <extra-json>. Never
# fails the caller.
_shunt_log_append() {
  local agent="$1" resp="$2" question="$3" files_json="$4" avoided="$5" extra="$6"

  mkdir -p "$(dirname "$SHUNT_DEBUG_LOG_PATH")" 2>/dev/null || return 0

  jq -n -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg agent "$agent" \
    --argjson files "$files_json" \
    --argjson qchars "${#question}" \
    --argjson avoided "$avoided" \
    --argjson extra "$extra" \
    --slurpfile usage <(jq -c '
      {input: (.usage.input // 0), output: (.usage.output // 0), cost: (.cost // 0)}
    ' "$resp" 2>/dev/null || echo '{"input":0,"output":0,"cost":0}') \
    '{
      timestamp: $ts,
      agent: $agent,
      files: $files,
      question_chars: $qchars,
      delegate_input_tokens: ($usage[0].input // 0),
      delegate_output_tokens: ($usage[0].output // 0),
      delegate_cost_usd: ($usage[0].cost // 0),
      avoided_tokens_estimate: $avoided
    } + $extra' >>"$SHUNT_DEBUG_LOG_PATH" 2>/dev/null || true
}

# shunt_log_usage <agent> <response-file> <question> <file...>
# Logs a bulk-read call: which delegate call this was, its real usage (from
# <response-file>, the same normalized response shunt_extract_usage reads), and a chars/4 estimate (evals/benchmark.sh's own
# documented heuristic) of the tokens Claude's context avoided by not reading
# <file...> directly. Never fails the caller: logging errors are swallowed
# since this is a debug aid, not part of the delegation path.
shunt_log_usage() {
  local agent="$1" resp="$2" question="$3"
  shift 3

  local files_json avoided
  files_json=$(_shunt_log_files_json "$@")
  avoided=$(echo "$files_json" | jq '[.[] | ((.bytes + 3) / 4 | floor)] | add // 0')
  _shunt_log_append "$agent" "$resp" "$question" "$files_json" "$avoided" '{"tool":"bulk-read"}'
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

  local files_json extra
  files_json=$(_shunt_log_files_json "$@")
  extra=$(jq -n -c --argjson b "$generated_bytes" \
    '{tool: "code-write", generated_bytes: $b, avoided_output_tokens_estimate: (($b + 3) / 4 | floor)}')
  _shunt_log_append "$agent" "$resp" "$spec" "$files_json" 0 "$extra"
}
