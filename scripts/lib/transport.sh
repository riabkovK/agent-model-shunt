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
# SHUNT_TOTAL_TIMEOUT_SECONDS (http transport only) is the deadline for one model
# attempt, every chunk and merge request of a chunked call included. It is per
# model, not per delegated call: when a model fails over, the next candidate
# starts with a fresh deadline of its own, so a failover chain can take up to
# this deadline once per candidate. When unset it is SHUNT_TOTAL_TIMEOUT_FACTOR
# times SHUNT_TIMEOUT_SECONDS (no total deadline when SHUNT_TIMEOUT_SECONDS is 0,
# that is no limit), worked out per attempt (see _shunt_http_init_deadline), so
# by default it never cuts a single request short.
SHUNT_TOTAL_TIMEOUT_FACTOR=3

# Exit statuses of shunt_transport_invoke that name the failure, so the failover
# loop can say why a model failed. Every failure a transport knows
# about has one of the statuses below and is explained on stderr. Any other
# non-zero status (1) is unexpected.
SHUNT_TRY_INVOKE_TIMEOUT=124
SHUNT_TRY_INVOKE_ERROR=2
SHUNT_TRY_INVOKE_EMPTY=3
# The provider rejected the key (HTTP 401/403). Not the model's fault, so the
# failover loop moves on to the next candidate without a breaker failure.
SHUNT_TRY_INVOKE_AUTH=4
# The http transport's total deadline (SHUNT_TOTAL_TIMEOUT_SECONDS) ended the
# call, as opposed to one request running past SHUNT_TIMEOUT_SECONDS (TIMEOUT).
SHUNT_TRY_INVOKE_DEADLINE=5
# The input is too large for this model, nothing was sent. Not the model's
# fault either: the failover loop tries the next candidate without a breaker
# failure, and when no candidate can take the input, Claude reads it itself.
SHUNT_TRY_INVOKE_OVERSIZE=6
# A config problem of this model (missing or unresolvable key, invalid base_url,
# request_body, oversize policy or total timeout, missing context_tokens or role
# prompt, an unusable providers.json or opencode agent). Nothing was sent and it says nothing about the model's health, so the
# failover loop explains it, tries the next candidate and records no breaker failure.
SHUNT_TRY_INVOKE_CONFIG=7

# What `opencode run -f <file>` keeps of an attached file. OpenCode reads an
# attachment with its read tool, which stops after DEFAULT_READ_LIMIT lines or
# MAX_BYTES bytes and cuts each line at MAX_LINE_LENGTH characters, without
# failing (packages/opencode/src/tool/read.ts, checked in the opencode 1.18.18
# binary: 2000 lines, 51200 bytes, 2000 characters). The model then answers
# from a silently truncated file, so a file over any of these is refused.
SHUNT_OPENCODE_MAX_FILE_LINES=2000
SHUNT_OPENCODE_MAX_FILE_BYTES=51200
SHUNT_OPENCODE_MAX_LINE_CHARS=2000

_SHUNT_TRANSPORT_LIB_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# the last text event, the reason of the last step_finish event, and tokens and
# cost summed over every step_finish (each step is billed on its own). OpenCode
# reports cached prompt tokens apart from tokens.input (tokens.cache.read and
# .write) and reasoning apart from tokens.output, so both are added back to
# match what an OpenAI-compatible API reports as prompt_tokens and
# completion_tokens. A transcript with no text yields empty text and one with no
# step_finish yields an empty finish reason and no usage key (so no usage line
# is printed), and so does output that is not JSON, so the callers' own checks
# (empty text, finish reason not "stop") judge it.
shunt_opencode_normalize() {
  local jsonl="$1"
  jq -s -c '
    def n: if type == "number" then . else 0 end;
    def obj: if type == "object" then . else {} end;
    ([.[] | select(.type=="text")] | last | .part.text // "") as $text |
    [.[] | select(.type=="step_finish") | .part | obj] as $steps |
    ($steps | last // {}) as $fin |
    [$steps[] | .cost | select(type == "number")] as $costs |
    {
      text: $text,
      finish_reason: ($fin.reason // ""),
      usage: {
        input: ([$steps[] | .tokens | obj | (.input | n) + (.cache | obj | (.read | n) + (.write | n))] | add // 0),
        output: ([$steps[] | .tokens | obj | (.output | n) + (.reasoning | n)] | add // 0)
      }
    }
    | if $steps == [] then del(.usage) else . end
    | . + (if $costs == [] then {} else {cost: ($costs | add)} end)
  ' "$jsonl" 2>/dev/null \
    || echo '{"text":"","finish_reason":""}'
}

# _shunt_opencode_file_too_big <file>
# Prints why OpenCode would truncate the attached file and succeeds, or fails
# (prints nothing) when the file fits. An unreadable file is left to opencode.
_shunt_opencode_file_too_big() {
  local f="$1" bytes stats lines longest
  [ -f "$f" ] && [ -r "$f" ] || return 1
  bytes=$(wc -c <"$f" | tr -d ' ')
  stats=$(awk '{ if (length($0) > m) m = length($0) } END { print NR, m + 0 }' "$f")
  lines=${stats% *} longest=${stats#* }
  if [ "$lines" -gt "$SHUNT_OPENCODE_MAX_FILE_LINES" ]; then
    echo "$lines lines, opencode keeps $SHUNT_OPENCODE_MAX_FILE_LINES"
  elif [ "$bytes" -gt "$SHUNT_OPENCODE_MAX_FILE_BYTES" ]; then
    echo "$bytes bytes, opencode keeps $SHUNT_OPENCODE_MAX_FILE_BYTES"
  elif [ "$longest" -gt "$SHUNT_OPENCODE_MAX_LINE_CHARS" ]; then
    echo "a line of $longest characters, opencode keeps $SHUNT_OPENCODE_MAX_LINE_CHARS"
  else
    return 1
  fi
}

# _shunt_opencode_guard_size <agent> <question> [file...]
# Refuses, with SHUNT_TRY_INVOKE_OVERSIZE and one stderr line, an input that
# opencode would truncate (see SHUNT_OPENCODE_MAX_FILE_LINES) or that exceeds
# the model's context budget when its context_tokens is known (the same
# estimate as the http transport's guard). Nothing is sent then.
_shunt_opencode_guard_size() {
  local agent="$1" question="$2" name f why bytes tokens budget
  shift 2
  name="${_SHUNT_HTTP_ID:-$agent}"
  for f in "$@"; do
    why=$(_shunt_opencode_file_too_big "$f") || continue
    echo "shunt: model $name: '$f' is too large for the opencode transport ($why), no request sent." >&2
    return "$SHUNT_TRY_INVOKE_OVERSIZE"
  done
  [ -n "${_SHUNT_HTTP_CONTEXT_TOKENS:-}" ] || return 0
  _shunt_http_check_context_tokens || return "$SHUNT_TRY_INVOKE_CONFIG"
  bytes=$(printf '%s' "$question" | wc -c | tr -d ' ')
  for f in "$@"; do
    [ -r "$f" ] || continue
    bytes=$(( bytes + $(wc -c <"$f" | tr -d ' ') ))
  done
  tokens=$(( (bytes + SHUNT_HTTP_BYTES_PER_TOKEN - 1) / SHUNT_HTTP_BYTES_PER_TOKEN ))
  budget=$(shunt_http_budget_tokens "$_SHUNT_HTTP_CONTEXT_TOKENS")
  [ "$tokens" -le "$budget" ] && return 0
  echo "shunt: model $name: input is too large for the model (about $tokens tokens, budget $budget), no request sent." >&2
  return "$SHUNT_TRY_INVOKE_OVERSIZE"
}

# _shunt_transport_opencode <agent> <question> [file...]
# Runs `opencode run --agent <agent> "<question>" -f <file> ... --format json`
# against an isolated OpenCode config (see shunt_prepare_isolated_config) and
# prints the path to a temp file holding the normalized response. Never exits
# the process on failure: returns one of the SHUNT_TRY_INVOKE_* statuses and
# cleans up after itself.
_shunt_transport_opencode() {
  local agent="$1" question="$2"
  shift 2

  local file_args=() f
  for f in "$@"; do
    # A relative path that starts with a dash would be parsed as an option.
    case "$f" in -*) f="./$f" ;; esac
    file_args+=(-f "$f")
  done

  _shunt_opencode_guard_size "$agent" "$question" "$@" || return $?

  local iso_config
  # shunt_prepare_isolated_config explains a missing agent or a broken config itself.
  iso_config=$(shunt_prepare_isolated_config "$agent") || return "$SHUNT_TRY_INVOKE_CONFIG"

  local raw out status=0
  raw=$(shunt_tmpfile) || { echo "shunt: cannot create a temp file for the opencode output." >&2; return "$SHUNT_TRY_INVOKE_ERROR"; }
  # </dev/null: opencode reads stdin, and this runs inside shunt_invoke_with_failover's
  # `while read ... <<<"$candidates"` loop, where it would swallow the remaining candidates.
  XDG_CONFIG_HOME="$iso_config" shunt_run_with_timeout \
    "$SHUNT_OPENCODE_BIN" run --agent "$agent" "$question" ${file_args[@]+"${file_args[@]}"} --format json \
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

  out=$(shunt_tmpfile) || { rm -f "$raw"; echo "shunt: cannot create a temp file for the opencode reply." >&2; return "$SHUNT_TRY_INVOKE_ERROR"; }
  shunt_opencode_normalize "$raw" >"$out"
  rm -f "$raw"
  echo "$out"
}

# shunt_transport_invoke <agent> <question> [file...]
# Dispatches on SHUNT_TRANSPORT (default opencode) and prints the path to the
# normalized response file. Returns the SHUNT_TRY_INVOKE_* statuses on a failed
# call: CONFIG, after saying why, for an unreadable providers.json or an
# unknown transport.
shunt_transport_invoke() {
  local transport status=0
  # The one registry lookup of this call. The http transport reuses it, and it
  # is forgotten afterwards so the next call sees registry edits.
  _shunt_http_resolve "$1" || true
  transport=$(_shunt_transport_of_resolved) || {
    _shunt_http_clear
    echo "shunt: cannot work out the transport of agent '$1': providers.json is unusable (config problem, no request sent)." >&2
    return "$SHUNT_TRY_INVOKE_CONFIG"
  }
  case "$transport" in
    opencode) _shunt_transport_opencode "$@" || status=$? ;;
    http) _shunt_transport_http "$@" || status=$? ;;
    *)
      echo "shunt: unknown transport '$transport' (supported: opencode, http)." >&2
      status=$SHUNT_TRY_INVOKE_CONFIG
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
