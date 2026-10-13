# Read-side plumbing for the shunt-owned delegate model registry
# (~/.config/agent-model-shunt/models.json by default). Lets shunt rotate
# across several delegate models instead of being pinned to the single
# hand-written OpenCode agent SHUNT_BULK_READER_AGENT names.
#
# The logic lives in scripts/py/shunt/models.py. Every function here is a thin
# wrapper around `shunt_py models <subcommand>` that keeps the old name, stdout,
# stderr and exit code. Each call that reaches Python costs one interpreter
# start. Callers that loop pay it per
# candidate. The no-registry legacy path stays free: shunt_models_available
# checks for the file in bash before spawning anything.
#
# Meant to be sourced by scripts/lib/opencode.sh. Requires scripts/lib/opencode.sh's
# shunt_report_error to already be sourced (or define your own).
#
# Compatibility: when no registry file exists at SHUNT_MODELS_FILE, every
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

# _shunt_models_py <subcommand> [args...]
# Runs a models subcommand with the paths this file resolved, exported only for
# the call (the variables may be unexported shell defaults).
_shunt_models_py() {
  SHUNT_MODELS_FILE="$SHUNT_MODELS_FILE" SHUNT_AGENTS_DIR="$SHUNT_AGENTS_DIR" \
    SHUNT_PROMPTS_DIR="$SHUNT_PROMPTS_DIR" shunt_py models "$@"
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

# shunt_models_has_role <id> <role>
# Success (0) when <id> has <role>. A model without a `roles` field has every
# role.
shunt_models_has_role() {
  _shunt_models_py has-role -- "$1" "$2" 2>/dev/null
}

# shunt_models_materialize_agent <id>
# Renders <id>'s OpenCode agent files into SHUNT_AGENTS_DIR: always the
# bulk-reader agent named in the registry (`models agent-for`), in the
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
