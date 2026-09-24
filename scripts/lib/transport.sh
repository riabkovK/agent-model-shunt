# Transport layer: how a delegated call reaches a model, behind one normalized
# response format. Every transport yields the path to one JSON file per
# successful call:
#
#   {"text": string, "finish_reason": string,
#    "usage": {"input": int, "output": int},   # absent if none was reported
#    "cost": number}          # cost only when the provider reported it
#
# The extractors and the debug log in opencode.sh read only this format, so a
# new transport only has to produce it. `opencode` (the OpenCode CLI) is the
# default, `http` (transport-http.sh) posts straight to an OpenAI-compatible
# API. The transport is chosen per provider, see shunt_transport_for_agent.
#
# Meant to be sourced by scripts/lib/opencode.sh, which supplies
# shunt_prepare_isolated_config, shunt_tmpfile and shunt_report_error.

SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-300}"

# Exit statuses of shunt_transport_invoke that name the failure, so the failover
# loop can say why a model failed. Any other non-zero status (1) means the agent
# or its config could not be prepared, which shunt_prepare_isolated_config (or
# the http transport) has already explained on stderr.
SHUNT_TRY_INVOKE_TIMEOUT=124
SHUNT_TRY_INVOKE_ERROR=2
SHUNT_TRY_INVOKE_EMPTY=3
# The provider rejected the key (HTTP 401/403). Not the model's fault, so the
# failover loop moves on to the next candidate without a breaker failure.
SHUNT_TRY_INVOKE_AUTH=4

_SHUNT_TRANSPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=providers.sh
source "$_SHUNT_TRANSPORT_LIB_DIR/providers.sh"
# shellcheck source=transport-http.sh
source "$_SHUNT_TRANSPORT_LIB_DIR/transport-http.sh"
unset _SHUNT_TRANSPORT_LIB_DIR

# shunt_run_with_timeout <command> [args...]
# Runs the command under SHUNT_TIMEOUT_SECONDS and returns its status, 124 when
# the time ran out. The one place that knows how a transport is time-limited.
shunt_run_with_timeout() {
  timeout "${SHUNT_TIMEOUT_SECONDS}" "$@"
}

# shunt_opencode_normalize <jsonl-file>
# Prints the normalized JSON for an `opencode run --format json` transcript:
# the last text event, and the tokens, cost and reason of the last step_finish
# event. A transcript with no text yields empty text and one with no step_finish
# yields an empty finish reason and no usage key (so no usage line is printed),
# and so does output that is not JSON, so the callers' own checks (empty text,
# finish reason not "stop") judge it.
shunt_opencode_normalize() {
  local jsonl="$1"
  jq -s -c '
    ([.[] | select(.type=="text")] | last | .part.text // "") as $text |
    ([.[] | select(.type=="step_finish")] | last | .part // {}) as $fin |
    {
      text: $text,
      finish_reason: ($fin.reason // ""),
      usage: {input: ($fin.tokens.input // 0), output: ($fin.tokens.output // 0)}
    }
    | if $fin == {} then del(.usage) else . end
    | . + (if $fin.cost == null then {} else {cost: $fin.cost} end)
  ' "$jsonl" 2>/dev/null \
    || echo '{"text":"","finish_reason":""}'
}

# _shunt_transport_opencode <agent> <question> [file...]
# Runs `opencode run --agent <agent> "<question>" -f <file> ... --format json`
# against an isolated OpenCode config (see shunt_prepare_isolated_config) and
# prints the path to a temp file holding the normalized response. Never exits
# the process on failure: returns one of the SHUNT_TRY_INVOKE_* statuses (or 1)
# and cleans up after itself.
_shunt_transport_opencode() {
  local agent="$1" question="$2"
  shift 2

  local file_args=() f
  for f in "$@"; do
    # A relative path that starts with a dash would be parsed as an option.
    case "$f" in -*) f="./$f" ;; esac
    file_args+=(-f "$f")
  done

  local iso_config
  iso_config=$(shunt_prepare_isolated_config "$agent") || return 1

  local raw out status=0
  raw=$(shunt_tmpfile)
  # </dev/null: opencode reads stdin, and this runs inside shunt_invoke_with_failover's
  # `while read ... <<<"$candidates"` loop, where it would swallow the remaining candidates.
  XDG_CONFIG_HOME="$iso_config" shunt_run_with_timeout \
    "$SHUNT_OPENCODE_BIN" run --agent "$agent" "$question" "${file_args[@]}" --format json \
    </dev/null >"$raw" 2>/dev/null || status=$?

  if [ "$status" -ne 0 ] || [ ! -s "$raw" ]; then
    rm -f "$raw"
    if [ "$status" -eq 124 ]; then
      return "$SHUNT_TRY_INVOKE_TIMEOUT"
    elif [ "$status" -ne 0 ]; then
      return "$SHUNT_TRY_INVOKE_ERROR"
    fi
    return "$SHUNT_TRY_INVOKE_EMPTY"
  fi

  out=$(shunt_tmpfile)
  shunt_opencode_normalize "$raw" >"$out"
  rm -f "$raw"
  echo "$out"
}

# shunt_transport_invoke <agent> <question> [file...]
# Dispatches on SHUNT_TRANSPORT (default opencode) and prints the path to the
# normalized response file. Returns the SHUNT_TRY_INVOKE_* statuses on a failed
# call, and 1 for an unknown transport.
shunt_transport_invoke() {
  local transport status=0
  # The one registry lookup of this call. The http transport reuses it, and it
  # is forgotten afterwards so the next call sees registry edits.
  _shunt_http_resolve "$1" || true
  transport=$(_shunt_transport_of_resolved) || { _shunt_http_clear; return 1; }
  case "$transport" in
    opencode) _shunt_transport_opencode "$@" || status=$? ;;
    http) _shunt_transport_http "$@" || status=$? ;;
    *)
      echo "shunt: unknown transport '$transport' (supported: opencode, http)." >&2
      status=1
      ;;
  esac
  _shunt_http_clear
  return "$status"
}

# _shunt_transport_of_resolved
# Prints the transport of the agent last resolved by _shunt_http_resolve: the
# SHUNT_TRANSPORT override when set (tests), otherwise models.json model ->
# provider (the id part before the first "/") -> providers.json transport. An
# unresolved agent (missing registry or model) or a provider without an entry
# means the implicit "opencode". Fails when providers.json is invalid.
_shunt_transport_of_resolved() {
  if [ -n "${SHUNT_TRANSPORT:-}" ]; then
    echo "$SHUNT_TRANSPORT"
    return 0
  fi
  [ -n "$_SHUNT_HTTP_ID" ] || { echo opencode; return 0; }
  shunt_provider_transport "${_SHUNT_HTTP_ID%%/*}"
}

# shunt_transport_for_agent <agent>
# Prints the transport for the agent's model, see _shunt_transport_of_resolved.
# For callers outside a delegated call (preflight checks): it does its own
# lookup and leaves nothing resolved behind.
shunt_transport_for_agent() {
  local transport status=0
  _shunt_http_resolve "$1" || true
  transport=$(_shunt_transport_of_resolved) || status=$?
  _shunt_http_clear
  [ "$status" -ne 0 ] || echo "$transport"
  return "$status"
}
