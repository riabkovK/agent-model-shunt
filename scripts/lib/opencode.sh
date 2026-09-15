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
SHUNT_ISOLATED_CONFIG_DIR="${SHUNT_ISOLATED_CONFIG_DIR:-$HOME/.cache/cc-model-shunt/opencode-config}"

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
shunt_prepare_isolated_config() {
  local agent="$1"
  local agent_file="$SHUNT_OPENCODE_CONFIG_HOME/agents/$agent.md"
  local iso_opencode="$SHUNT_ISOLATED_CONFIG_DIR/opencode"

  [ -f "$agent_file" ] \
    || shunt_report_error "OpenCode agent '$agent' not found at $agent_file. See README's Setup section."

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

  echo "$SHUNT_ISOLATED_CONFIG_DIR"
}

# shunt_invoke <agent> <question> [file...]
# Runs `opencode run --agent <agent> "<question>" -f <file> ... --format json`
# against an isolated OpenCode config (see shunt_prepare_isolated_config) and
# prints the path to a temp file holding the raw JSONL stdout.
shunt_invoke() {
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
  iso_config=$(shunt_prepare_isolated_config "$agent")

  local out status
  out=$(shunt_tmpfile)
  status=0
  XDG_CONFIG_HOME="$iso_config" timeout "${SHUNT_TIMEOUT_SECONDS}" \
    "$SHUNT_OPENCODE_BIN" run --agent "$agent" "$question" "${file_args[@]}" --format json \
    >"$out" 2>/dev/null || status=$?

  if [ "$status" -ne 0 ]; then
    rm -f "$out"
    if [ "$status" -eq 124 ]; then
      shunt_report_error "opencode run timed out after ${SHUNT_TIMEOUT_SECONDS}s (agent: $agent). Increase SHUNT_TIMEOUT_SECONDS or reduce the input."
    fi
    shunt_report_error "opencode run failed (exit $status, agent: $agent)."
  fi

  if [ ! -s "$out" ]; then
    rm -f "$out"
    shunt_report_error "opencode run produced no output (agent: $agent)."
  fi

  echo "$out"
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
