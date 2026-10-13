#!/bin/bash
# `shunt-models dashboard`: everything the /model-config dashboard shows, in
# one call and one stable line format. Meant to be sourced by
# scripts/shunt-models after opencode.sh, models.sh, providers.sh and
# migrate.sh.
#
# The report itself (the line format is documented at the top of the module)
# is scripts/py/shunt/dashboard.py. The paths resolved by the bash libraries are
# passed for this call only, since they may be unexported shell defaults. No API
# key is passed or printed: key_present only says whether one resolves, and an
# env-type key is read by Python from the environment the caller exported.

# cmd_dashboard
cmd_dashboard() {
  [ $# -eq 0 ] || shunt_report_error "usage: shunt-models dashboard"
  SHUNT_MODELS_FILE="$SHUNT_MODELS_FILE" SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" \
    SHUNT_PROC_VERSION_FILE="$SHUNT_PROC_VERSION_FILE" SHUNT_OPENCODE_CONFIG_HOME="$SHUNT_OPENCODE_CONFIG_HOME" \
    SHUNT_BREAKER_STATE_FILE="$SHUNT_BREAKER_STATE_FILE" SHUNT_BREAKER_CONFIG_FILE="$SHUNT_BREAKER_CONFIG_FILE" \
    SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE="${SHUNT_CODE_WRITE_SELF_FIX_CONFIG_FILE:-}" \
    shunt_py dashboard
}
