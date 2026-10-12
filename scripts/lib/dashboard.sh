#!/bin/bash
# `shunt-models dashboard`: everything the /model-config dashboard shows, in
# one call and one stable line format. Meant to be sourced by
# scripts/shunt-models after opencode.sh (which sources breaker.sh),
# models.sh, providers.sh and migrate.sh.
#
# Output, one record per line, fields separated by single spaces, values
# never contain spaces (names, ids and base_urls are validated elsewhere):
#   registry: ok|missing|invalid
#   providers_file: ok|missing|invalid
#   provider <name> transport=<t> base_url=<url|-> key=<type|env:VAR> key_present=yes|no|unknown
#     (yes for key type none; unknown while providers.json is invalid)
#   provider <name> invalid
#   model <id> enabled=yes|no active=yes|no roles=<r,...> thinking=on|off
#         thinking_off=set|none context_tokens=<n|unset>
#         oversize_policy=<map_reduce|fail>(|default) provider_transport=<t>
#   breaker threshold=<n> default=3 cooldown_seconds=<n> default=300 status=enabled|disabled
#   breaker_state <id> <bulk-read|code-write> failures=<n> open=true|false
#   self_fix_retries=<n> default=1
#   first_choice <bulk-read|code-write> <id|none>
#   opencode config=present|absent importable=<name,...|none>
#   issue <code> <subject>
#   setup: empty|opencode-importable|incomplete|ok
# A key value is never printed: key_present only says whether one resolves.
# The model lines are printed on one line each (wrapped above for reading).

# Mirrors SHUNT_BREAKER_DISABLED_THRESHOLD in scripts/shunt-breaker-config.
_DASHBOARD_BREAKER_DISABLED_THRESHOLD=999999999
_DASHBOARD_ISSUES=()

# _dashboard_providers_state
# Prints ok, missing or invalid for providers.json.
_dashboard_providers_state() {
  [ -f "$SHUNT_PROVIDERS_FILE" ] || { echo missing; return 0; }
  if jq -e '(.providers | type) == "object"' "$SHUNT_PROVIDERS_FILE" >/dev/null 2>&1 \
    && shunt_providers_validate >/dev/null 2>&1; then
    echo ok
  else
    echo invalid
  fi
}

# _dashboard_key_present <provider>
# Prints yes when the provider's key resolves (always for type none), else no.
# The resolved key goes to /dev/null and never into a variable.
_dashboard_key_present() {
  if shunt_provider_key_resolve "$1" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# _dashboard_providers <providers-state>
_dashboard_providers() {
  local state="$1" name rest present
  case "$state" in
    missing) return 0 ;;
    invalid)
      jq -e '(.providers | type) == "object"' "$SHUNT_PROVIDERS_FILE" >/dev/null 2>&1 || return 0 ;;
  esac
  while IFS=$'\t' read -r name rest; do
    if [[ "$rest" == invalid:* ]]; then
      echo "provider $name invalid"
      _DASHBOARD_ISSUES+=("provider-invalid $name")
      continue
    fi
    local transport base_url key
    IFS=$'\t' read -r transport base_url key <<<"$rest"
    # Keys are not looked up while the file is invalid: every lookup fails.
    present=unknown
    [ "$state" = ok ] && present=$(_dashboard_key_present "$name")
    echo "provider $name transport=$transport base_url=$base_url key=$key key_present=$present"
    if [ "$transport" = http ] && [ "$present" = no ]; then
      _DASHBOARD_ISSUES+=("key-missing $name")
    fi
  done < <(shunt_providers_list_lines)
}

# _dashboard_provider_transport <provider> <providers-state>
_dashboard_provider_transport() {
  if [ "$2" = ok ]; then
    shunt_provider_transport "$1"
  else
    echo opencode
  fi
}

# _dashboard_models <providers-state>
_dashboard_models() {
  local pstate="$1" id rest provider transport
  while IFS=$'\t' read -r id rest; do
    provider="${id%%/*}"
    transport=$(_dashboard_provider_transport "$provider" "$pstate")
    echo "model $id $rest provider_transport=$transport"
    if [ "$transport" = http ] && [[ "$rest" == *"context_tokens=unset"* ]]; then
      _DASHBOARD_ISSUES+=("context-missing $id")
    fi
  done < <(jq -r --argjson all_roles "$SHUNT_MODELS_ROLES_JSON" '
    .active as $active
    | .models[]
    | "\(.id)\tenabled=\(if .enabled == false then "no" else "yes" end)"
      + " active=\(if .id == $active then "yes" else "no" end)"
      + " roles=\((.roles // $all_roles) | join(","))"
      + " thinking=\(if .thinking == true or .thinking == "on" then "on" else "off" end)"
      + " thinking_off=\(if .thinking_off_options == null then "none" else "set" end)"
      + " context_tokens=\(.context_tokens // "unset")"
      + " oversize_policy=\(.oversize_policy // "map_reduce(default)")"
  ' "$SHUNT_MODELS_FILE")
}

# _dashboard_breaker
_dashboard_breaker() {
  local status=enabled id
  [ "$SHUNT_BREAKER_THRESHOLD" -lt "$_DASHBOARD_BREAKER_DISABLED_THRESHOLD" ] || status=disabled
  echo "breaker threshold=$SHUNT_BREAKER_THRESHOLD default=3 cooldown_seconds=$SHUNT_BREAKER_COOLDOWN_SECONDS default=300 status=$status"
  shunt_models_available || return 0
  while IFS= read -r id; do
    if shunt_models_has_role "$id" bulk-read; then
      echo "breaker_state $id bulk-read $(shunt_breaker_status "$id")"
    fi
    if shunt_models_has_role "$id" code-write; then
      echo "breaker_state $id code-write $(shunt_breaker_status "$(shunt_breaker_key "$id" code-write)")"
    fi
  done < <(jq -r '.models[].id' "$SHUNT_MODELS_FILE")
}

# _dashboard_first_choices
# Prints the first candidate per role, the same lookup the delegates use.
_dashboard_first_choices() {
  local role candidates
  for role in "${SHUNT_MODELS_ROLES[@]}"; do
    candidates=""
    shunt_models_available && candidates=$(shunt_models_candidates "$role" quiet 2>/dev/null || true)
    echo "first_choice $role ${candidates%%$'\n'*}" | sed 's/ $/ none/'
  done
}

# _dashboard_importable
# Prints the comma-joined opencode providers that the migration would pick
# up (migrate.sh's own detection), minus those already on the http transport.
_dashboard_importable() {
  shunt_models_available || return 0
  [ -f "$(_migrate_opencode_json)" ] || return 0
  local http_names='[]'
  if [ "$(_dashboard_providers_state)" = ok ]; then
    http_names=$(jq -c '[.providers | to_entries[] | select(.value.transport == "http") | .key]' "$SHUNT_PROVIDERS_FILE")
  fi
  { _migrate_collect_providers 2>/dev/null || true; } \
    | jq -r -s --argjson h "$http_names" '[.[].name | select(IN($h[]) | not)] | join(",")'
}

# _dashboard_setup <registry-state> <providers-state> <importable>
_dashboard_setup() {
  local rstate="$1" pstate="$2" importable="$3" models=0 providers=0 http=0
  [ "$rstate" = ok ] && models=$(jq '.models | length' "$SHUNT_MODELS_FILE")
  if [ "$pstate" != missing ]; then
    providers=$(jq '.providers | length' "$SHUNT_PROVIDERS_FILE" 2>/dev/null || echo 1)
    http=$(jq '[.providers[] | select(.transport == "http")] | length' "$SHUNT_PROVIDERS_FILE" 2>/dev/null || echo 0)
  fi
  if [ "$rstate" != invalid ] && [ "$pstate" != invalid ] && [ "$models" -eq 0 ] && [ "$providers" -eq 0 ]; then
    echo "setup: empty"
  elif [ "$rstate" = ok ] && [ "$pstate" != invalid ] && [ "$http" -eq 0 ] && [ -n "$importable" ]; then
    echo "setup: opencode-importable"
  elif [ "${#_DASHBOARD_ISSUES[@]}" -gt 0 ]; then
    echo "setup: incomplete"
  else
    echo "setup: ok"
  fi
}

# _dashboard_registry_issues <registry-state>
_dashboard_registry_issues() {
  case "$1" in
    invalid) _DASHBOARD_ISSUES+=("registry-invalid models.json") ;;
    ok)
      if [ "$(jq '.models | length' "$SHUNT_MODELS_FILE")" -eq 0 ]; then
        _DASHBOARD_ISSUES+=("no-models -")
      elif [ -z "$(shunt_models_candidates bulk-read quiet 2>/dev/null || true)" ]; then
        _DASHBOARD_ISSUES+=("no-bulk-read-model -")
      fi ;;
    missing) _DASHBOARD_ISSUES+=("no-models -") ;;
  esac
}

# cmd_dashboard
cmd_dashboard() {
  [ $# -eq 0 ] || shunt_report_error "usage: shunt-models dashboard"
  _DASHBOARD_ISSUES=()
  local rstate=missing pstate importable issue
  if [ -f "$SHUNT_MODELS_FILE" ]; then
    rstate=invalid
    shunt_models_available && rstate=ok
  fi
  pstate=$(_dashboard_providers_state)
  echo "registry: $rstate"
  echo "providers_file: $pstate"
  _dashboard_providers "$pstate"
  [ "$rstate" = ok ] && _dashboard_models "$pstate"
  _dashboard_breaker
  echo "self_fix_retries=$SHUNT_CODE_WRITE_SELF_FIX_RETRIES default=1"
  _dashboard_first_choices
  importable=$(_dashboard_importable)
  echo "opencode config=$([ -f "$(_migrate_opencode_json)" ] && echo present || echo absent) importable=${importable:-none}"
  [ "$pstate" != invalid ] || _DASHBOARD_ISSUES+=("providers-invalid providers.json")
  _dashboard_registry_issues "$rstate"
  for issue in ${_DASHBOARD_ISSUES[@]+"${_DASHBOARD_ISSUES[@]}"}; do
    echo "issue $issue"
  done
  _dashboard_setup "$rstate" "$pstate" "$importable"
}
