# Self-fix loop retry-count config for code-write. The loop itself lives in
# skills/code-writer/SKILL.md orchestration, not in codewrite.sh; this file
# only resolves how many times that orchestration may re-call `code-write`
# on a mechanical build/test failure before falling back to Claude fixing
# the file by hand.
#
# Config precedence: hardcoded default -> SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE
# (if present and valid) -> SHUNT_CODE_WRITE_SELF_FIX_RETRIES env var, which
# stays the emergency/test override on top of everything else. Read once
# here, at source time, mirroring breaker.sh's threshold/cooldown precedence.
#
# Meant to be sourced by scripts/shunt-codewrite-config. Requires jq.

SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE="${SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE:-$HOME/.config/agent-model-shunt/code-write-self-fix-config.json}"

# _shunt_self_fix_uint_or <value> <fallback>
# Sets REPLY to <value> as a decimal integer when it is 1 to 15 digits
# (0 included), else to <fallback>. Same digit-only guard as
# breaker.sh's _shunt_breaker_uint_or, for the same reason: this value can
# reach bash arithmetic in the orchestration loop.
_shunt_self_fix_uint_or() {
  local value="${1-}" fallback="$2"
  if [[ "$value" =~ ^[0-9]{1,15}$ ]]; then
    REPLY=$((10#$value))
  else
    REPLY="$fallback"
  fi
}

_shunt_self_fix_default_retries=1

_shunt_self_fix_config_retries=""
if [ -f "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" ]; then
  _shunt_self_fix_config_retries=$(jq -r '.self_fix_retries // empty' "$SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE" 2>/dev/null) || _shunt_self_fix_config_retries=""
fi

_shunt_self_fix_uint_or "$_shunt_self_fix_config_retries" "$_shunt_self_fix_default_retries"
_shunt_self_fix_uint_or "${SHUNT_CODE_WRITE_SELF_FIX_RETRIES:-}" "$REPLY"
SHUNT_CODE_WRITE_SELF_FIX_RETRIES="$REPLY"

unset _shunt_self_fix_default_retries _shunt_self_fix_config_retries
