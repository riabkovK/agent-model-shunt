# HTTP transport: one non-streaming POST to <base_url>/chat/completions of an
# OpenAI-compatible provider, normalized into the response format described in
# transport.sh. Meant to be sourced by transport.sh, which supplies the
# SHUNT_TRY_INVOKE_* statuses and SHUNT_TIMEOUT_SECONDS. Needs models.sh.
#
# The whole call (registry lookup, base_url check, request body, size guard, the
# total deadline, POST, status mapping, map_reduce chunking for an oversize input,
# normalized reply) lives in scripts/py/shunt: transport_http.py, transport_reply.py,
# deadline.py, chunking.py and chunk_plan.py. It is one `shunt_py transport
# http-call` process per call, no curl and no jq. The status table is in the header
# of transport_http.py. This file is the wrapper plus the registry helpers
# transport.sh and the opencode guard use.
# Secret rules: the key only ever lives in the memory of the Python process. It is
# never in argv, a file, a child environment or on stderr. Redirects are never
# followed, so the Authorization header cannot be replayed to another host.

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

# Oversize guard: tokens are estimated as ceil(bytes / SHUNT_HTTP_BYTES_PER_TOKEN)
# and must fit in SHUNT_HTTP_CONTEXT_BUDGET_PERCENT of the model's context_tokens.
# Python (transport_http.py, chunking.py) applies the same numbers to a request.
# The values here are for the dispatcher and the opencode guard.
SHUNT_HTTP_BYTES_PER_TOKEN=3
SHUNT_HTTP_CONTEXT_BUDGET_PERCENT=60
SHUNT_HTTP_MAX_CONTEXT_DIGITS=12

# shunt_http_budget_tokens <context_tokens>
# Prints the tokens a request may use: SHUNT_HTTP_CONTEXT_BUDGET_PERCENT of the
# context window, rounded down.
shunt_http_budget_tokens() {
  # Only plain decimal digits reach the arithmetic: anything else (empty, a
  # sign, an array subscript with a command substitution) counts as 0.
  [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] || { echo 0; return 0; }
  echo $(( 10#$1 * SHUNT_HTTP_CONTEXT_BUDGET_PERCENT / 100 ))
}

# The registry entry of the agent being called, resolved once per delegated call
# by _shunt_http_resolve and shared by the dispatcher (transport choice) and the
# opencode guard. Empty _SHUNT_HTTP_AGENT means unresolved.
_SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE=""
# Optional registry fields of the same entry, empty when absent.
_SHUNT_HTTP_CONTEXT_TOKENS="" _SHUNT_HTTP_OVERSIZE_POLICY=""

# _shunt_http_clear
# Forgets the resolved entry so a later call reads the registry afresh.
_shunt_http_clear() {
  _SHUNT_HTTP_AGENT="" _SHUNT_HTTP_ID="" _SHUNT_HTTP_ROLE=""
  _SHUNT_HTTP_CONTEXT_TOKENS="" _SHUNT_HTTP_OVERSIZE_POLICY=""
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

# _shunt_http_call <agent> <question> [file...]
# The work of _shunt_transport_http: one `shunt_py transport http-call` process.
# The paths and limits are passed per call: they may be unexported shell variables.
# The key is read by Python itself. Prints the normalized response file path, which
# the caller owns. Returns a SHUNT_TRY_INVOKE_* status (or 1 when a chunk could not
# be cut), anything else is reported as ERROR.
_shunt_http_call() {
  local status=0 out
  out=$(SHUNT_MODELS_FILE="$SHUNT_MODELS_FILE" SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" \
    SHUNT_PROC_VERSION_FILE="$SHUNT_PROC_VERSION_FILE" SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" \
    SHUNT_TIMEOUT_SECONDS="$SHUNT_TIMEOUT_SECONDS" \
    SHUNT_TOTAL_TIMEOUT_SECONDS="${SHUNT_TOTAL_TIMEOUT_SECONDS:-}" \
    SHUNT_HTTP_MAX_CHUNKS="${SHUNT_HTTP_MAX_CHUNKS:-}" \
    shunt_py transport http-call -- "$@") || status=$?
  case "$status" in
    0) echo "$out" ;;
    1 | "$SHUNT_TRY_INVOKE_TIMEOUT" | "$SHUNT_TRY_INVOKE_ERROR" | "$SHUNT_TRY_INVOKE_EMPTY" \
      | "$SHUNT_TRY_INVOKE_AUTH" | "$SHUNT_TRY_INVOKE_DEADLINE" | "$SHUNT_TRY_INVOKE_OVERSIZE" \
      | "$SHUNT_TRY_INVOKE_CONFIG") return "$status" ;;
    *)
      echo "shunt: the HTTP transport failed unexpectedly (exit $status)." >&2
      return "$SHUNT_TRY_INVOKE_ERROR"
      ;;
  esac
}

# _shunt_transport_http <agent> <question> [file...]
# Prints the path to a temp file holding the normalized response. Never exits
# the process: returns a SHUNT_TRY_INVOKE_* status, always with the reason
# already explained on stderr. The only file is the response, which Python
# writes last, so there is nothing to clean up on INT and TERM.
_shunt_transport_http() {
  local status=0
  _shunt_http_call "$@" || status=$?
  _shunt_http_clear
  return "$status"
}
