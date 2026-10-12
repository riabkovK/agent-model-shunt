# Read-side plumbing for the shunt-owned delegate model registry
# (~/.config/agent-model-shunt/models.json by default). Lets shunt rotate
# across several delegate models instead of being pinned to the single
# hand-written OpenCode agent SHUNT_BULK_READER_AGENT names.
#
# The logic lives in scripts/py/shunt/models.py. Every function here is a thin
# wrapper around `shunt_py models <subcommand>` that keeps the old name, stdout,
# stderr and exit code. Each call that reaches Python costs one interpreter
# start. Callers that loop (shunt_invoke_role_with_failover) pay it per
# candidate. The no-registry legacy path stays free: shunt_models_available
# checks for the file in bash before spawning anything.
#
# Meant to be sourced by scripts/bulk-read, scripts/shunt-models, and
# scripts/lib/opencode.sh. Requires scripts/lib/opencode.sh's
# shunt_report_error to already be sourced (or define your own).
#
# Compatibility: when no registry file exists at shunt_models_file, every
# function here fails closed (shunt_models_available returns non-zero) so
# callers can fall back to the legacy single-agent path untouched.

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

SHUNT_MODELS_FILE="${SHUNT_MODELS_FILE:-$HOME/.config/agent-model-shunt/models.json}"
SHUNT_AGENTS_DIR="${SHUNT_AGENTS_DIR:-$HOME/.config/agent-model-shunt/agents}"
# The role prompts (bulk-reader.md, code-writer.md): the body of the OpenCode
# agent files and the system message of the http transport. The default is
# derived without a subshell, since the Read hook sources this file on every Read.
SHUNT_PROMPTS_DIR="${SHUNT_PROMPTS_DIR:-${BASH_SOURCE[0]%/*}/../../prompts}"

# Roles a model can be assigned in the registry's optional `roles` array. A
# model without `roles` has all of them. The JSON form is kept literal next to
# the bash array so sourcing this file (the Read hook does, on every Read)
# never has to spawn a process to build it. Keep them in sync with ROLES in
# scripts/py/shunt/models.py.
SHUNT_MODELS_ROLES=(bulk-read code-write)
SHUNT_MODELS_ROLES_JSON='["bulk-read","code-write"]'

# jq definitions of the agent names, still used by scripts/lib/transport-http.sh
# for the per-row names in _shunt_http_resolve until that file is ported. The
# Python twin is slug_core in scripts/py/shunt/models.py.
SHUNT_MODELS_SLUG_JQ='def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
  def bulk_agent: if (.agent // "") == "" then "shunt-bulk-reader-" + (.id | slug) else .agent end;
  def writer_agent: "shunt-code-writer-" + (.id | slug);'

# _shunt_models_py <subcommand> [args...]
# Runs a models subcommand with the paths this file resolved, exported only for
# the call (the variables may be unexported shell defaults).
_shunt_models_py() {
  SHUNT_MODELS_FILE="$SHUNT_MODELS_FILE" SHUNT_AGENTS_DIR="$SHUNT_AGENTS_DIR" \
    SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" shunt_py models "$@"
}

# shunt_models_file
# Prints the path to the registry file.
shunt_models_file() {
  echo "$SHUNT_MODELS_FILE"
}

# shunt_models_available
# Success (0) if a registry file exists and is valid; failure (1) otherwise
# (missing file, or present but invalid). Never prints an error: this is
# the legacy-mode detection point, not a place to surface validation noise.
#
# The interpreter itself failing (not found 127, not executable 126, too old 2)
# is not "no registry": it still returns 1 so callers take the safe legacy
# path, but prints one warning line on stderr so the fallback is not silent.
shunt_models_available() {
  [ -f "$SHUNT_MODELS_FILE" ] || return 1
  local rc=0
  _shunt_models_py available >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  echo "shunt: the Python interpreter is unusable (exit $rc), treating the models registry as absent." >&2
  return 1
}

# shunt_models_validate
# Validates the registry file's shape. Prints nothing on success. On
# failure, prints a one-line reason to stdout (callers using `run` in tests
# assert on it) and returns non-zero.
shunt_models_validate() {
  _shunt_models_py validate
}

# shunt_models_role_known <role>
# Success (0) if <role> is one of SHUNT_MODELS_ROLES.
shunt_models_role_known() {
  local role="$1" known
  for known in "${SHUNT_MODELS_ROLES[@]}"; do
    [ "$role" = "$known" ] && return 0
  done
  return 1
}

# shunt_models_candidates [role] [quiet]
# Prints, one per line, the enabled model ids that have <role> (default
# bulk-read, so legacy callers keep working) in the order to try them: the
# registry's `active` model first (if it is enabled and has the role), then
# the remaining matching entries in priority (array) order, deduped. A model
# without a `roles` field has every role. Prints nothing when no enabled
# model has the role, and callers decide what that means. Requires
# shunt_models_validate to already have passed; callers should check
# shunt_models_available first.
#
# Warns on stderr when `active` names a model that is not in the registry.
# Pass "quiet" as the second argument to suppress that warning, for a caller
# that looks the candidates up a second time in the same run and would
# otherwise print it twice.
#
# Disabled models (`enabled: false`; a missing field counts as enabled)
# never become candidates, so the breaker is not consulted for them at all.
shunt_models_candidates() {
  local role="${1:-bulk-read}" quiet="${2:-}"
  if ! shunt_models_role_known "$role"; then
    echo "shunt: unknown role '$role' (known roles: ${SHUNT_MODELS_ROLES[*]})." >&2
    return 1
  fi
  _shunt_models_py candidates "$role" "$quiet" || return 1
}

# shunt_models_agent_for <id>
# Prints the materialized agent name registered for <id>. An entry without an
# `agent` field (hand-edited) gets the name `add` would have given it. An id
# that is not in the registry prints nothing.
shunt_models_agent_for() {
  _shunt_models_py agent-for -- "$1" || return 1
}

# shunt_models_thinking_for <id>
# Prints "true" or "false" for whether <id> has thinking/extended-reasoning
# enabled.
shunt_models_thinking_for() {
  _shunt_models_py thinking-for -- "$1"
}

# shunt_models_thinking_options_for <id>
# Prints the raw thinking_options JSON for <id> (or "null").
shunt_models_thinking_options_for() {
  _shunt_models_py thinking-options-for -- "$1"
}

# shunt_models_thinking_off_options_for <id>
# Prints the raw thinking_off_options JSON for <id> (or "null"). A registry
# written before this field existed reads as null.
shunt_models_thinking_off_options_for() {
  _shunt_models_py thinking-off-options-for -- "$1"
}

# _shunt_models_slug_core <id>
# Lowercase, dash-separated form of a provider/model id, shared by every
# agent name derived from the id.
_shunt_models_slug_core() {
  _shunt_models_py slug-core -- "$1"
}

# shunt_models_slug <id>
# Derives a lowercase, dash-separated OpenCode agent name from a
# provider/model id, e.g. "Spark/deepseek-ai/DeepSeek-V4-Flash-0731" ->
# "shunt-bulk-reader-spark-deepseek-ai-deepseek-v4-flash-0731".
shunt_models_slug() {
  _shunt_models_py slug -- "$1"
}

# shunt_models_code_writer_agent_for <id>
# Prints the name of <id>'s code-writer agent, e.g. "shunt-code-writer-spark-
# deepseek-ai-deepseek-v4-flash-0731". Derived from the id, not stored in the
# registry: it exists only while the model has the code-write role.
shunt_models_code_writer_agent_for() {
  _shunt_models_py code-writer-agent-for -- "$1"
}

# shunt_models_has_role <id> <role>
# Success (0) when <id> has <role>. A model without a `roles` field has every
# role.
shunt_models_has_role() {
  _shunt_models_py has-role -- "$1" "$2" 2>/dev/null
}

# _shunt_models_thinking_block <id>
# Prints the extra agent frontmatter lines for <id>'s thinking options, or
# nothing. thinking defaults OFF (docs/TODO.md): reasoning-related frontmatter
# is omitted unless the user explicitly turned thinking on and supplied
# provider-specific options (flat key/value pairs) via `shunt-models thinking
# <id> on <json>`. Those pairs are passed through verbatim as extra top-level
# agent frontmatter fields, since OpenCode's AgentConfig accepts arbitrary
# provider-specific keys and their shape varies by provider. A model may also
# carry explicit off options, rendered the same way while thinking is off and
# never while it is on.
_shunt_models_thinking_block() {
  _shunt_models_py thinking-block -- "$1"
}

# shunt_models_require_prompts [role...]
# Exits with an error unless the role prompt files are readable. bulk-reader.md
# is always needed (every model gets a bulk-reader agent file), code-writer.md
# only when the roles given include code-write. Run it before a registry write,
# so a missing prompt cannot leave the registry changed.
shunt_models_require_prompts() {
  _shunt_models_py require-prompts -- "$@" || exit 1
}

# shunt_models_materialize_agent <id>
# Renders <id>'s OpenCode agent files into SHUNT_AGENTS_DIR: always the
# bulk-reader agent named in the registry (shunt_models_agent_for), in the
# same frontmatter shape as the hand-written bulk-reader.md convention
# documented in README.md, and the code-writer agent only while the model has
# the code-write role. A code-writer agent left over from a role that has
# since been dropped is removed, so the files always match the registry.
# Called only at registry-edit time (scripts/shunt-models), never per
# scripts/bulk-read or scripts/code-write call. Exits on error, like
# shunt_report_error.
shunt_models_materialize_agent() {
  _shunt_models_py materialize -- "$1" || exit 1
}
