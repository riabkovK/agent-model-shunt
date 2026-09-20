# Read-side plumbing for the shunt-owned delegate model registry
# (~/.config/agent-model-shunt/models.json by default). Lets shunt rotate
# across several delegate models instead of being pinned to the single
# hand-written OpenCode agent SHUNT_BULK_READER_AGENT names.
#
# Meant to be sourced by scripts/bulk-read, scripts/shunt-models, and
# scripts/lib/opencode.sh. Requires scripts/lib/opencode.sh's
# shunt_report_error to already be sourced (or define your own).
#
# Compatibility: when no registry file exists at shunt_models_file, every
# function here fails closed (shunt_models_available returns non-zero) so
# callers can fall back to the legacy single-agent path untouched.

SHUNT_MODELS_FILE="${SHUNT_MODELS_FILE:-$HOME/.config/agent-model-shunt/models.json}"
SHUNT_AGENTS_DIR="${SHUNT_AGENTS_DIR:-$HOME/.config/agent-model-shunt/agents}"

# shunt_models_file
# Prints the path to the registry file.
shunt_models_file() {
  echo "$SHUNT_MODELS_FILE"
}

# shunt_models_available
# Success (0) if a registry file exists and is valid; failure (1) otherwise
# (missing file, or present but invalid). Never prints an error: this is
# the legacy-mode detection point, not a place to surface validation noise.
shunt_models_available() {
  [ -f "$SHUNT_MODELS_FILE" ] || return 1
  shunt_models_validate >/dev/null 2>&1
}

# shunt_models_validate
# Validates the registry file's shape. Prints nothing on success. On
# failure, prints a one-line reason to stdout (callers using `run` in tests
# assert on it) and returns non-zero.
shunt_models_validate() {
  [ -f "$SHUNT_MODELS_FILE" ] || { echo "shunt: models registry not found at $SHUNT_MODELS_FILE"; return 1; }

  if ! jq -e . "$SHUNT_MODELS_FILE" >/dev/null 2>&1; then
    echo "shunt: models registry at $SHUNT_MODELS_FILE contains invalid JSON."
    return 1
  fi

  # An empty models array is valid: it means "no delegate models
  # configured", under which the Read hook stops redirecting reads.
  local dupes
  dupes=$(jq -r '[.models[].id] | group_by(.) | map(select(length > 1)) | flatten | unique | .[]' "$SHUNT_MODELS_FILE" 2>/dev/null || true)
  if [ -n "$dupes" ]; then
    echo "shunt: models registry at $SHUNT_MODELS_FILE has duplicate model id(s): $(echo "$dupes" | tr '\n' ' ')"
    return 1
  fi

  return 0
}

# shunt_models_candidates
# Prints, one per line, the enabled model ids to try in order: the registry's
# `active` model first (if it names a real, enabled entry), then the
# remaining enabled entries in priority (array) order, deduped. Prints
# nothing when the registry has no enabled models. Requires shunt_models_validate
# to already have passed; callers should check shunt_models_available first.
shunt_models_candidates() {
  local active
  active=$(jq -r '.active // empty' "$SHUNT_MODELS_FILE")

  if [ -n "$active" ]; then
    local known
    known=$(jq -r --arg a "$active" '[.models[].id] | index($a) // empty' "$SHUNT_MODELS_FILE")
    if [ -z "$known" ]; then
      echo "shunt: models registry's active model '$active' is not in the models list; falling back to priority order." >&2
      active=""
    fi
  fi

  # Disabled models (`enabled: false`; a missing field counts as enabled)
  # never become candidates, so they cost nothing per call: the breaker is
  # not consulted for them at all. A disabled active model is skipped
  # silently and keeps its `active` marker for when it is re-enabled.
  jq -r --arg a "$active" '
    [.models[] | select(.enabled != false) | .id] as $ids
    | (if $a != "" and ($ids | index($a)) != null then [$a] else [] end) as $head
    | ($head + ($ids - $head))
    | .[]
  ' "$SHUNT_MODELS_FILE"
}

# shunt_models_agent_for <id>
# Prints the materialized agent name registered for <id>.
shunt_models_agent_for() {
  local id="$1"
  jq -r --arg id "$id" '.models[] | select(.id == $id) | .agent' "$SHUNT_MODELS_FILE"
}

# shunt_models_thinking_for <id>
# Prints "true" or "false" for whether <id> has thinking/extended-reasoning
# enabled.
shunt_models_thinking_for() {
  local id="$1"
  jq -r --arg id "$id" '.models[] | select(.id == $id) | (.thinking // false)' "$SHUNT_MODELS_FILE"
}

# shunt_models_thinking_options_for <id>
# Prints the raw thinking_options JSON for <id> (or "null").
shunt_models_thinking_options_for() {
  local id="$1"
  jq -c --arg id "$id" '.models[] | select(.id == $id) | (.thinking_options // null)' "$SHUNT_MODELS_FILE"
}

# shunt_models_slug <id>
# Derives a lowercase, dash-separated OpenCode agent name from a
# provider/model id, e.g. "Spark/deepseek-ai/DeepSeek-V4-Flash-0731" ->
# "shunt-bulk-reader-spark-deepseek-ai-deepseek-v4-flash-0731".
shunt_models_slug() {
  local id="$1"
  local slug
  slug=$(echo "$id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  echo "shunt-bulk-reader-$slug"
}

# shunt_models_materialize_agent <id>
# Renders an OpenCode agent markdown file for <id> into SHUNT_AGENTS_DIR,
# using the agent name registered for <id> (shunt_models_agent_for), in the
# same frontmatter shape as the hand-written bulk-reader.md convention
# documented in README.md. Called only at registry-edit time
# (scripts/shunt-models), never per scripts/bulk-read call.
shunt_models_materialize_agent() {
  local id="$1"
  local agent
  agent=$(shunt_models_agent_for "$id")
  [ -n "$agent" ] || shunt_report_error "no registered agent name for model '$id'."

  # thinking defaults OFF (docs/TODO.md): omit any reasoning-related
  # frontmatter unless the user explicitly turned thinking on and supplied
  # provider-specific options (flat key/value pairs) via `shunt-models
  # thinking <id> on <json>`. Those pairs are passed through verbatim as
  # extra top-level agent frontmatter fields, since OpenCode's AgentConfig
  # accepts arbitrary provider-specific keys and their shape varies by
  # provider (e.g. Anthropic's "thinking" object vs. OpenAI's
  # "reasoningEffort" string) - shunt doesn't hardcode one provider's shape.
  local thinking thinking_options thinking_block
  thinking=$(shunt_models_thinking_for "$id")
  thinking_options=$(shunt_models_thinking_options_for "$id")
  thinking_block=""
  if [ "$thinking" = "true" ] && [ "$thinking_options" != "null" ]; then
    thinking_block=$(echo "$thinking_options" | jq -r 'to_entries[] | "\(.key): \(.value)"')
  fi

  mkdir -p "$SHUNT_AGENTS_DIR"
  local agent_file="$SHUNT_AGENTS_DIR/$agent.md"
  local tmp_file
  tmp_file=$(mktemp "$SHUNT_AGENTS_DIR/.$agent.md.XXXXXX")

  {
    cat <<AGENT
---
description: Precise, read-only code analyst for delegated bulk-read questions.
mode: primary
model: $id
AGENT
    [ -n "$thinking_block" ] && echo "$thinking_block"
    cat <<AGENT
tools:
  read: true
  bash: false
  write: false
  edit: false
  glob: false
  grep: false
  task: false
  webfetch: false
  todowrite: false
  skill: false
  changed-files: false
  dependency-analyzer: false
---

You are a precise code analyst. Answer the question about the attached
file(s) directly and concisely. Use bullet points, not prose. Do not
speculate beyond what is in the attached content. Do not suggest edits or
next steps unless asked.
AGENT
  } >"$tmp_file"

  mv "$tmp_file" "$agent_file"
}
