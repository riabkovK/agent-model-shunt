# Transport layer: how a delegated call reaches a model, behind one normalized
# response format. Every transport yields the path to one JSON file per
# successful call:
#
#   {"text": string, "finish_reason": string,
#    "usage": {"input": int, "output": int},   # absent if none was reported
#    "cost": number}          # cost only when the provider reported it
#
# The extractors and the debug log in opencode.sh read only this format, so a
# new transport (e.g. a direct HTTP client) only has to produce it. `opencode`
# (the OpenCode CLI) is the only transport today and the default.
#
# Meant to be sourced by scripts/lib/opencode.sh, which supplies
# shunt_prepare_isolated_config, shunt_tmpfile and shunt_report_error.

SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-300}"

# Exit statuses of shunt_transport_invoke that name the failure, so the failover
# loop can say why a model failed. Any other non-zero status (1) means the agent
# or its config could not be prepared, which shunt_prepare_isolated_config has
# already explained on stderr.
SHUNT_TRY_INVOKE_TIMEOUT=124
SHUNT_TRY_INVOKE_ERROR=2
SHUNT_TRY_INVOKE_EMPTY=3

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
  local transport="${SHUNT_TRANSPORT:-opencode}"
  case "$transport" in
    opencode) _shunt_transport_opencode "$@" ;;
    *)
      echo "shunt: unknown transport '$transport' (supported: opencode)." >&2
      return 1
      ;;
  esac
}
