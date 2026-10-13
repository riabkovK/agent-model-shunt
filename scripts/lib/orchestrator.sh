# Fragment library for the orchestrator rule: a short delegation rule that is
# assembled from per-skill fragment files (skills/*/orchestrator.md) and the
# user's own fragments. The logic (parsing, sanitizing, listing, rendering)
# lives in scripts/py/shunt/orchestrator.py. These functions are thin wrappers
# around it for tests and tooling, with the same names, stdout and exit codes
# as the old bash functions. The SessionStart hook does not source this file,
# it runs the Python module directly.
#
# Fragment format: an optional first line `role: <name>`, then 1 to 6 bullet
# lines that each start with `- `. Anything else makes the fragment invalid
# (non-zero return, no output).
#
# Meant to be sourced. Compatibility: bash 3.2 safe.

# Plugin root, derived without a subshell.
_SHUNT_ORCHESTRATOR_SELF="${BASH_SOURCE[0]}"
case "$_SHUNT_ORCHESTRATOR_SELF" in
  */*) _SHUNT_ORCHESTRATOR_DIR="${_SHUNT_ORCHESTRATOR_SELF%/*}" ;;
  *) _SHUNT_ORCHESTRATOR_DIR=. ;;
esac
_SHUNT_ORCHESTRATOR_ROOT="$_SHUNT_ORCHESTRATOR_DIR/../.."
# shellcheck source=py.sh
source "$_SHUNT_ORCHESTRATOR_DIR/py.sh"

# shunt_orchestrator_min_lines <value>
# Prints <value> if it is a plain positive integer of at most 9 digits,
# otherwise the default (350).
shunt_orchestrator_min_lines() {
  shunt_py orchestrator min-lines -- "${1:-}"
}

# shunt_orchestrator_role <file>
# Prints the fragment's role (empty line if it declares none). Non-zero and no
# output when the fragment is invalid.
shunt_orchestrator_role() {
  shunt_py orchestrator role -- "$1"
}

# shunt_orchestrator_body <file> [min_lines]
# Prints the sanitized bullet lines with {{MIN_LINES}} substituted. Non-zero
# and no output when the fragment is invalid.
shunt_orchestrator_body() {
  shunt_py orchestrator body -- "$1" ${2+"$2"}
}

# shunt_orchestrator_list [plugin_root]
# Prints fragment paths, one per line: the built-ins (skills/*/orchestrator.md)
# sorted bytewise, then the valid user fragments sorted the same way. A user
# fragment named like a skill directory (bulk-reader.md) replaces that
# built-in. Only regular, non-symlink, user-owned, non-dotfile .md files in a
# trusted directory are taken.
shunt_orchestrator_list() {
  shunt_py orchestrator list -- "${1:-$_SHUNT_ORCHESTRATOR_ROOT}"
}

# shunt_orchestrator_render [plugin_root]
# Prints the plain-text delegation rule for session start, capped at 3000
# characters. Prints nothing and returns non-zero when the registry exists but
# cannot be read.
shunt_orchestrator_render() {
  shunt_py orchestrator render -- "${1:-$_SHUNT_ORCHESTRATOR_ROOT}"
}
