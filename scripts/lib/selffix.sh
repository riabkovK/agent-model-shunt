# Self-fix loop retry-count config for code-write. The loop itself lives in
# skills/code-writer/SKILL.md orchestration, not in the Python code-write path; this file
# only resolves how many times that orchestration may re-call `code-write`
# on a mechanical build/test failure before falling back to Claude fixing
# the file by hand.
#
# Config precedence: hardcoded default -> SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE
# (if present and valid) -> SHUNT_CODE_WRITE_SELF_FIX_RETRIES env var, which
# stays the emergency/test override on top of everything else. Resolved by
# scripts/py/shunt/selffix.py, read once here at source time, mirroring
# breaker.sh's threshold/cooldown precedence.
#
# Meant to be sourced by scripts/shunt-codewrite-config. Needs python3.

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE="${SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE:-$HOME/.config/agent-model-shunt/code-write-self-fix-config.json}"

# A dead interpreter, or an answer that is not a plain count, gives the
# default of 1 (the digit guard matters: the value reaches bash arithmetic).
_shunt_self_fix_retries=$(shunt_py selffix retries -- "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" "${SHUNT_CODE_WRITE_SELF_FIX_RETRIES:-}" 2>/dev/null) || _shunt_self_fix_retries=""
case "$_shunt_self_fix_retries" in
  ''|*[!0-9]*) _shunt_self_fix_retries=1 ;;
  *) [ "${#_shunt_self_fix_retries}" -le 15 ] || _shunt_self_fix_retries=1 ;;
esac
SHUNT_CODE_WRITE_SELF_FIX_RETRIES=$((10#$_shunt_self_fix_retries))
unset _shunt_self_fix_retries
