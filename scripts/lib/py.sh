# Bridge from bash to the Python core (scripts/py/). Ported bash functions
# become thin wrappers around shunt_py with the same name, stdout and exit code.
#
# Meant to be sourced. SHUNT_PYTHON overrides the interpreter. -I ignores
# PYTHON* env vars and user site dirs, -B keeps __pycache__ out of the plugin dir.
#
# Compatibility: bash 3.2 safe.

SHUNT_PY_MAIN="${SHUNT_PY_MAIN:-${BASH_SOURCE[0]%/*}/../py/shunt_main.py}"

shunt_py() {
  "${SHUNT_PYTHON:-python3}" -I -B "$SHUNT_PY_MAIN" "$@"
}
