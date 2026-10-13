# HTTP transport: one non-streaming POST to <base_url>/chat/completions of an
# OpenAI-compatible provider, normalized into the response format described in
# transport.sh. Meant to be sourced by transport.sh, which supplies the
# SHUNT_TRY_INVOKE_* statuses and SHUNT_TIMEOUT_SECONDS. Needs providers.sh and
# models.sh, and shunt_tmpfile from opencode.sh.
#
# The request itself (registry lookup, base_url check, request body, size guard,
# POST, status mapping, normalized reply) lives in scripts/py/shunt/transport_http.py
# and transport_reply.py: one `shunt_py transport` process per request, no curl and
# no jq. The status table is in the header of transport_http.py. This file keeps
# the total deadline (transport-http-deadline.sh), the map_reduce chunking
# (transport-http-chunking.sh) and the helpers those two call.
# Secret rules: the key only ever lives in the memory of the Python process. It is
# never in argv, a file, a child environment or on stderr. Redirects are never
# followed, so the Authorization header cannot be replayed to another host.

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

# Oversize guard: tokens are estimated as ceil(bytes / SHUNT_HTTP_BYTES_PER_TOKEN)
# and must fit in SHUNT_HTTP_CONTEXT_BUDGET_PERCENT of the model's context_tokens.
# Python (transport_http.py) applies the guard to a single request. The values
# here are for the chunk planner and the dispatcher.
SHUNT_HTTP_BYTES_PER_TOKEN=3
SHUNT_HTTP_CONTEXT_BUDGET_PERCENT=60
SHUNT_HTTP_MAX_CONTEXT_DIGITS=12
# map_reduce chunking. Neighbouring chunks of a file share this many lines, and
# a chunk request carries at least SHUNT_HTTP_MIN_CHUNK_BYTES of file content.
# The framing of a chunk request (question, "part i of n" note, block markers)
# is measured per file, see _shunt_http_chunk_overhead. Partial answers are
# merged in at most SHUNT_HTTP_MAX_MERGE_DEPTH group rounds.
# SHUNT_HTTP_PARTIAL_RESERVE_BYTES is the marker overhead assumed per partial
# answer in a merge request.
SHUNT_HTTP_CHUNK_OVERLAP_LINES=20
SHUNT_HTTP_MIN_CHUNK_BYTES=200
SHUNT_HTTP_MAX_MERGE_DEPTH=3
# A call that would need more chunk requests than this fails before sending any.
SHUNT_HTTP_MAX_CHUNKS=100
SHUNT_HTTP_PARTIAL_RESERVE_BYTES=100
# Exit status of `shunt_py transport http-call` when the input needs chunking
# (transport_reply.NEEDS_CHUNKING). Never returned to callers.
SHUNT_HTTP_NEEDS_CHUNKING=90
SHUNT_HTTP_MERGE_INSTRUCTION="The input was too large to send at once, so it was analysed in parts. Below are the partial answers to the question above, one per part. Neighbouring parts of one file share $SHUNT_HTTP_CHUNK_OVERLAP_LINES lines, so the same finding can appear twice. Combine them into one final answer to the question, without repeating duplicates."
_SHUNT_HTTP_TMP=()

_SHUNT_HTTP_LIB_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=transport-http-deadline.sh
source "$_SHUNT_HTTP_LIB_DIR/transport-http-deadline.sh"
# shellcheck source=transport-http-chunking.sh
source "$_SHUNT_HTTP_LIB_DIR/transport-http-chunking.sh"

# shunt_http_budget_tokens <context_tokens>
# Prints the tokens a request may use: SHUNT_HTTP_CONTEXT_BUDGET_PERCENT of the
# context window, rounded down.
shunt_http_budget_tokens() {
  # Only plain decimal digits reach the arithmetic: anything else (empty, a
  # sign, an array subscript with a command substitution) counts as 0.
  [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] || { echo 0; return 0; }
  echo $(( 10#$1 * SHUNT_HTTP_CONTEXT_BUDGET_PERCENT / 100 ))
}

# _shunt_rm_tracked <file-var> <list-var>
# Removes the file named by the variable <file-var> and every file in the array
# <list-var>, then empties both. Both arguments must be plain variable names,
# otherwise it returns 1 and touches nothing.
_shunt_rm_tracked() {
  local _shunt_rt_re='^[A-Za-z_][A-Za-z0-9_]*$' _shunt_rt_f
  [[ "$1" =~ $_shunt_rt_re && "$2" =~ $_shunt_rt_re ]] || return 1
  eval "_shunt_rt_f=\${$1:-}"
  [ -z "$_shunt_rt_f" ] || rm -f -- "$_shunt_rt_f"
  printf -v "$1" '%s' ""
  # Iterate over the values, not indexes, so a sparse array leaks nothing.
  # The ${a[@]+...} form keeps an empty array safe under set -u on bash 3.2.
  eval "for _shunt_rt_f in \${$2[@]+\"\${$2[@]}\"}; do rm -f -- \"\$_shunt_rt_f\"; done"
  eval "$2=()"
}

# _shunt_http_cleanup
# Removes every temp file the current call created.
_shunt_http_cleanup() {
  local _shunt_http_none=""
  _shunt_rm_tracked _shunt_http_none _SHUNT_HTTP_TMP
}

# _shunt_http_new_tmp <varname>
# Creates a 0600 temp file, remembers it for cleanup and stores its path in the
# named variable. Not a command substitution, so the cleanup list survives.
# An environment failure (no temp file) is explained and returns ERROR.
_shunt_http_new_tmp() {
  local f
  f=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-http.XXXXXX" 2>/dev/null) \
    || { echo "shunt: cannot create a temp file in ${TMPDIR:-/tmp}." >&2; return "$SHUNT_TRY_INVOKE_ERROR"; }
  _SHUNT_HTTP_TMP+=("$f")
  printf -v "$1" '%s' "$f"
}

# The registry entry of the agent being called, resolved once per delegated call
# by _shunt_http_resolve and shared by the dispatcher (transport choice), the
# deadline messages and the chunk planner. Empty _SHUNT_HTTP_AGENT means unresolved.
_SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE=""
# Optional registry fields of the same entry, empty when absent.
_SHUNT_HTTP_CONTEXT_TOKENS="" _SHUNT_HTTP_OVERSIZE_POLICY=""
# The role prompt, loaded by _shunt_http_setup for the chunk planner.
_SHUNT_HTTP_SYSTEM="" _SHUNT_HTTP_OUT=""

# _shunt_http_clear
# Forgets the resolved entry so a later call reads the registry afresh.
_shunt_http_clear() {
  _SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE=""
  _SHUNT_HTTP_CONTEXT_TOKENS="" _SHUNT_HTTP_OVERSIZE_POLICY=""
  _SHUNT_HTTP_SYSTEM=""
}

# _shunt_http_resolve <agent>
# One registry read: finds the model whose bulk-reader or code-writer agent is
# <agent> and sets _SHUNT_HTTP_ID, _SHUNT_HTTP_ROLE (bulk-reader|code-writer)
# and the optional _SHUNT_HTTP_CONTEXT_TOKENS and _SHUNT_HTTP_OVERSIZE_POLICY
# (empty when absent). Fields are split on the unit separator, a non-whitespace
# delimiter, so empty fields keep their column. Must run in the current shell,
# not in $(...). Fails, leaving nothing resolved, when the registry is missing or
# has no such model.
_shunt_http_resolve() {
  local agent="$1" id a w ct op
  _shunt_http_clear
  shunt_models_available || return 1
  while IFS=$'\x1f' read -r id a w ct op; do
    if [ "$agent" = "$a" ]; then
      _SHUNT_HTTP_ROLE=bulk-reader
    elif [ "$agent" = "$w" ]; then
      _SHUNT_HTTP_ROLE=code-writer
    else
      continue
    fi
    _SHUNT_HTTP_AGENT="$agent" _SHUNT_HTTP_ID="$id"
    _SHUNT_HTTP_CONTEXT_TOKENS="$ct" _SHUNT_HTTP_OVERSIZE_POLICY="$op"
    return 0
  done < <(jq -r "$SHUNT_MODELS_SLUG_JQ"' .models[] | [.id, bulk_agent, writer_agent, ((.context_tokens // "") | if type == "number" then floor | tostring else tostring end), (.oversize_policy // "")] | join("\u001f")' "$SHUNT_MODELS_FILE")
  return 1
}

# _shunt_http_system_prompt <role> <outvar>
# Stores the role prompt in <outvar>: prompts/code-writer.md or
# prompts/bulk-reader.md. The same files are the body of the materialized
# OpenCode agent files. A missing or unreadable file is a config problem
# (incomplete plugin install).
_shunt_http_system_prompt() {
  local role="$1" file
  file="$SHUNT_PROMPTS_DIR/$role.md"
  [ -f "$file" ] && [ -r "$file" ] \
    || { echo "shunt: the $role prompt is missing at $file (incomplete plugin install)." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  printf -v "$2" '%s' "$(<"$file")"
}

# _shunt_http_resolved <agent>
# Resolves the agent unless the dispatcher already did. A CONFIG error when the
# registry has no such model.
_shunt_http_resolved() {
  [ "$_SHUNT_HTTP_AGENT" = "$1" ] || _shunt_http_resolve "$1" \
    || { echo "shunt: no model in the registry for agent '$1'." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
}

# _shunt_http_setup <agent>
# Resolves the agent and loads its role prompt into _SHUNT_HTTP_SYSTEM, what the
# chunk planner measures. The requests validate everything else themselves.
_shunt_http_setup() {
  _shunt_http_resolved "$1" || return $?
  _shunt_http_system_prompt "$_SHUNT_HTTP_ROLE" _SHUNT_HTTP_SYSTEM
}

# _shunt_http_append_file <outfile> <label> <file>
# Appends the file's content to the prompt in a block labelled with <label>.
_shunt_http_append_file() {
  [ -f "$3" ] && [ -r "$3" ] || { echo "shunt: cannot read attached file '$3'." >&2; return "$SHUNT_TRY_INVOKE_CONFIG"; }
  { printf '\n--- file: %s ---\n' "$2"; cat -- "$3"; printf '\n--- end of file ---\n'; } >>"$1"
}

# _shunt_http_build_chunk_prompt <outfile> <question> <label> <chunk-file>
# The question, then the chunk in a block labelled with the original file's
# name instead of the chunk temp file.
_shunt_http_build_chunk_prompt() {
  printf '%s\n' "$2" >"$1"
  _shunt_http_append_file "$1" "$3" "$4"
}

# _shunt_http_check_context_tokens
# Fails with a message unless the resolved context_tokens is empty or a plain
# integer of at most SHUNT_HTTP_MAX_CONTEXT_DIGITS digits (a hand-edited value
# such as 1e30 would otherwise abort bash arithmetic).
_shunt_http_check_context_tokens() {
  local ct="$_SHUNT_HTTP_CONTEXT_TOKENS"
  [ -z "$ct" ] && return 0
  if [[ "$ct" =~ ^[1-9][0-9]*$ ]] && [ "${#ct}" -le "$SHUNT_HTTP_MAX_CONTEXT_DIGITS" ]; then
    return 0
  fi
  echo "shunt: model $_SHUNT_HTTP_ID has an invalid context_tokens in models.json (config problem, no request sent). Run: shunt-models set-context $_SHUNT_HTTP_ID <tokens>." >&2
  return 1
}

# _shunt_http_py <http-call|http-ask> <agent> <arg>...
# Runs one `shunt_py transport` request with the max time of this request (the
# total deadline may cut it, see transport-http-deadline.sh). The paths are passed
# per call: they may be unexported shell variables. The key is read by Python
# itself. On success _SHUNT_HTTP_OUT holds the normalized response file, which the
# caller owns. Returns a SHUNT_TRY_INVOKE_* status, or SHUNT_HTTP_NEEDS_CHUNKING.
_shunt_http_py() {
  local sub="$1" status=0 out
  shift
  _SHUNT_HTTP_OUT=""
  _shunt_http_request_max_time || return $?
  out=$(SHUNT_MODELS_FILE="$SHUNT_MODELS_FILE" SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" \
    SHUNT_PROC_VERSION_FILE="$SHUNT_PROC_VERSION_FILE" SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" \
    SHUNT_HTTP_MAX_TIME="$_SHUNT_HTTP_MAX_TIME" shunt_py transport "$sub" -- "$@") || status=$?
  case "$status" in
    0 | "$SHUNT_HTTP_NEEDS_CHUNKING" | "$SHUNT_TRY_INVOKE_TIMEOUT" | "$SHUNT_TRY_INVOKE_ERROR" \
      | "$SHUNT_TRY_INVOKE_EMPTY" | "$SHUNT_TRY_INVOKE_AUTH" | "$SHUNT_TRY_INVOKE_OVERSIZE" \
      | "$SHUNT_TRY_INVOKE_CONFIG") ;;
    *)
      echo "shunt: the HTTP transport failed unexpectedly (exit $status)." >&2
      status=$SHUNT_TRY_INVOKE_ERROR
      ;;
  esac
  # A request cut short by the remaining time ran into the total deadline.
  if [ "$status" -eq "$SHUNT_TRY_INVOKE_TIMEOUT" ] && [ "$_SHUNT_HTTP_MAX_TIME_CAPPED" = 1 ]; then
    _shunt_http_deadline_note
    status=$SHUNT_TRY_INVOKE_DEADLINE
  fi
  [ "$status" -ne 0 ] || _SHUNT_HTTP_OUT="$out"
  return "$status"
}

# _shunt_http_ask <prompt-file>
# One request for a prompt file (a chunk or merge request of the resolved agent).
# On success _SHUNT_HTTP_OUT holds the normalized response file.
_shunt_http_ask() {
  _shunt_http_py http-ask "$_SHUNT_HTTP_AGENT" "$1"
}

# _shunt_http_call <agent> <question> [file...]
# The work of _shunt_transport_http. Temp files are registered for cleanup by
# the caller. Prints the normalized response file path on success.
_shunt_http_call() {
  local agent="$1" question="$2" status=0
  shift 2
  _shunt_http_init_deadline || return $?
  _shunt_http_resolved "$agent" || return $?
  _shunt_http_py http-call "$agent" "$question" "$@" || status=$?
  case "$status" in
    0) echo "$_SHUNT_HTTP_OUT" ;;
    "$SHUNT_HTTP_NEEDS_CHUNKING")
      _shunt_http_setup "$agent" || return $?
      _shunt_http_map_reduce "$question" "$@"
      ;;
    *) return "$status" ;;
  esac
}

# _shunt_transport_http <agent> <question> [file...]
# Prints the path to a temp file holding the normalized response. Never exits
# the process: returns a SHUNT_TRY_INVOKE_* status, always with the reason
# already explained on stderr. The temp files are removed on every exit path,
# INT and TERM too. The caller's INT and TERM traps are restored afterwards.
_shunt_transport_http() {
  local saved_int saved_term saved_hup status=0
  saved_int=$(trap -p INT)
  saved_term=$(trap -p TERM)
  saved_hup=$(trap -p HUP)
  _SHUNT_HTTP_TMP=()
  trap '_shunt_http_cleanup; exit 130' INT
  trap '_shunt_http_cleanup; exit 143' TERM
  trap '_shunt_http_cleanup; exit 129' HUP

  _shunt_http_call "$@" || status=$?

  _shunt_http_clear
  _shunt_http_cleanup
  if [ -n "$saved_int" ]; then eval "$saved_int"; else trap - INT; fi
  if [ -n "$saved_term" ]; then eval "$saved_term"; else trap - TERM; fi
  if [ -n "$saved_hup" ]; then eval "$saved_hup"; else trap - HUP; fi
  return "$status"
}
