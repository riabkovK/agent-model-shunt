# Shared plumbing for delegating work to a custom model via the OpenCode CLI.
# Analogous to shunt's aika.sh, but shells out to `opencode run` (opencode.ai)
# instead of Spotify's Portal CLI, and targets user-configured OpenCode
# providers/agents instead of Spotify AiKA modes.
#
# Meant to be sourced by scripts/bulk-read and future scripts/code-write.

SHUNT_OPENCODE_BIN="${SHUNT_OPENCODE_BIN:-opencode}"
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-300}"
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

  mkdir -p "$iso_opencode/agents"
  cp "$agent_file" "$iso_opencode/agents/$agent.md"

  local provider
  provider=$(awk -F'[/: ]+' '/^model:/{print $2; exit}' "$agent_file")

  if [ -n "$provider" ] && [ -f "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json" ]; then
    jq --arg p "$provider" '{provider: {($p): .provider[$p]}}' \
      "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json" >"$iso_opencode/opencode.json" \
      || shunt_report_error "failed to build isolated OpenCode config from $SHUNT_OPENCODE_CONFIG_HOME/opencode.json."
  else
    echo '{}' >"$iso_opencode/opencode.json"
  fi

  echo "$iso_root"
}

# shunt_try_invoke <agent> <question> [file...]
# Runs `opencode run --agent <agent> "<question>" -f <file> ... --format json`
# against an isolated OpenCode config (see shunt_prepare_isolated_config) and
# prints the path to a temp file holding the raw JSONL stdout. Unlike
# shunt_invoke, never exits the process on failure (agent not found,
# opencode error, timeout, empty output): returns non-zero and cleans up
# after itself, so shunt_invoke_with_failover can try the next candidate
# model instead of the whole delegated call dying on one bad model.
shunt_try_invoke() {
  local agent="$1"
  local question="$2"
  shift 2
  local files=("$@")

  local file_args=()
  local f
  for f in "${files[@]}"; do
    file_args+=(-f "$f")
  done

  local iso_config
  iso_config=$(shunt_prepare_isolated_config "$agent") || return 1

  local out status
  out=$(shunt_tmpfile)
  status=0
  # </dev/null: opencode reads stdin, and this runs inside shunt_invoke_with_failover's
  # `while read ... <<<"$candidates"` loop, where it would swallow the remaining candidates.
  XDG_CONFIG_HOME="$iso_config" timeout "${SHUNT_TIMEOUT_SECONDS}" \
    "$SHUNT_OPENCODE_BIN" run --agent "$agent" "$question" "${file_args[@]}" --format json \
    </dev/null >"$out" 2>/dev/null || status=$?

  if [ "$status" -ne 0 ] || [ ! -s "$out" ]; then
    rm -f "$out"
    return 1
  fi

  echo "$out"
}

# shunt_invoke <agent> <question> [file...]
# Legacy single-agent path: same call as shunt_try_invoke, but fatal (via
# shunt_report_error) on any failure. Used directly when no models.json
# registry exists yet (no breaker/failover to fall back on), and internally
# by shunt_invoke_with_failover for that same legacy case.
shunt_invoke() {
  local agent="$1" question="$2"
  shift 2
  local out
  if ! out=$(shunt_try_invoke "$agent" "$question" "$@"); then
    shunt_report_error "opencode run failed for agent '$agent' (not found, timed out after ${SHUNT_TIMEOUT_SECONDS}s, exited non-zero, or produced no output)."
  fi
  echo "$out"
}

# shunt_invoke_with_failover <question> [file...]
# Delegates a call, trying candidate models in the shunt-owned models.json
# registry (priority order, skipping any whose circuit breaker is open) and
# recording each attempt's outcome via shunt_breaker_record_success/
# _failure. Falls back to the single legacy SHUNT_BULK_READER_AGENT
# unchanged (no breaker involved) when no registry exists yet. Sets
# SHUNT_INVOKE_OUT_FILE to the successful call's output file path and
# SHUNT_INVOKE_AGENT_USED to the model id (or legacy agent name) that
# produced it. Both are globals, not stdout: a caller that captured stdout
# with $(...) would run this in a subshell and lose the second variable, so
# call it directly, never inside a command substitution. Fatal only once
# every candidate has been tried and failed, or every registered
# candidate's breaker is currently open.
shunt_invoke_with_failover() {
  local question="$1"
  shift
  local files=("$@")

  if ! shunt_models_available; then
    SHUNT_INVOKE_OUT_FILE=$(shunt_invoke "$SHUNT_BULK_READER_AGENT" "$question" "${files[@]}")
    SHUNT_INVOKE_AGENT_USED="$SHUNT_BULK_READER_AGENT"
    return 0
  fi

  local candidates
  candidates=$(shunt_models_candidates)
  [ -n "$candidates" ] || shunt_report_error "no enabled delegate models in the registry at $(shunt_models_file). Read the file directly instead, or add/enable a model with scripts/shunt-models."

  local id agent out tried_any=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    shunt_breaker_is_open "$id" && continue
    tried_any=1
    agent=$(shunt_models_agent_for "$id")
    if out=$(shunt_try_invoke "$agent" "$question" "${files[@]}"); then
      shunt_breaker_record_success "$id"
      SHUNT_INVOKE_AGENT_USED="$id"
      SHUNT_INVOKE_OUT_FILE="$out"
      return 0
    fi
    shunt_breaker_record_failure "$id"
  done <<<"$candidates"

  if [ -z "$tried_any" ]; then
    shunt_report_error "every delegate model in the registry is currently paused (circuit breaker open); no candidates available."
  fi
  shunt_report_error "all delegate models in the registry failed for this call."
}

# shunt_extract_text <jsonl-file>
# Prints the final assistant text event from an `opencode run --format json` transcript.
shunt_extract_text() {
  local jsonl="$1"
  local text
  text=$(jq -s -r '[.[] | select(.type=="text")] | last | .part.text // empty' "$jsonl" 2>/dev/null || true)

  if [ -z "$text" ]; then
    shunt_report_error "could not extract assistant text from opencode output (raw transcript kept at $jsonl for inspection)."
  fi

  echo "$text"
}

# shunt_extract_usage <jsonl-file>
# Prints a one-line "input=N output=N cost=N" usage summary, or nothing if unavailable.
shunt_extract_usage() {
  local jsonl="$1"
  jq -s -r '
    [.[] | select(.type=="step_finish")] | last | .part |
    if . == null then empty else
      "input=" + (.tokens.input // 0 | tostring) +
      " output=" + (.tokens.output // 0 | tostring) +
      " cost=" + (.cost // 0 | tostring)
    end
  ' "$jsonl" 2>/dev/null || true
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

# shunt_log_usage <agent> <jsonl-file> <question> <file...>
# Appends one JSON line to SHUNT_DEBUG_LOG_PATH recording: which delegate
# call this was, its real usage (from <jsonl-file>, the same
# `opencode run --format json` transcript shunt_extract_usage reads), and a
# chars/4 estimate (evals/benchmark.sh's own documented heuristic) of the
# tokens Claude's context avoided by not reading <file...> directly. Never
# fails the caller: logging errors are swallowed since this is a debug aid,
# not part of the delegation path.
shunt_log_usage() {
  local agent="$1" jsonl="$2" question="$3"
  shift 3
  local files=("$@")

  mkdir -p "$(dirname "$SHUNT_DEBUG_LOG_PATH")" 2>/dev/null || return 0

  local files_json avoided_tokens=0
  files_json="[]"
  local f bytes lines
  for f in "${files[@]}"; do
    bytes=$(wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0)
    lines=$(wc -l <"$f" 2>/dev/null | tr -d ' ' || echo 0)
    avoided_tokens=$((avoided_tokens + (bytes + 3) / 4))
    files_json=$(echo "$files_json" | jq -c --arg p "$f" --argjson b "$bytes" --argjson l "$lines" \
      '. + [{path: $p, lines: $l, bytes: $b}]')
  done

  jq -n -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg agent "$agent" \
    --argjson files "$files_json" \
    --argjson qchars "${#question}" \
    --argjson avoided "$avoided_tokens" \
    --slurpfile usage <(jq -s -r '
      [.[] | select(.type=="step_finish")] | last | .part |
      if . == null then {input:0,output:0,cost:0}
      else {input: (.tokens.input // 0), output: (.tokens.output // 0), cost: (.cost // 0)} end
    ' "$jsonl" 2>/dev/null || echo '{"input":0,"output":0,"cost":0}') \
    '{
      timestamp: $ts,
      agent: $agent,
      files: $files,
      question_chars: $qchars,
      delegate_input_tokens: ($usage[0].input // 0),
      delegate_output_tokens: ($usage[0].output // 0),
      delegate_cost_usd: ($usage[0].cost // 0),
      avoided_tokens_estimate: $avoided
    }' >>"$SHUNT_DEBUG_LOG_PATH" 2>/dev/null || true
}
