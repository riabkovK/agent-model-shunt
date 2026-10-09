#!/bin/bash
# Migration from the OpenCode config to the HTTP transport:
# `shunt-models --migrate-from-opencode [--apply] [--key-storage <how>]`.
# Meant to be sourced by scripts/shunt-models after opencode.sh, models.sh,
# providers.sh and context-detect.sh.
#
# Source of truth is $SHUNT_OPENCODE_CONFIG_HOME/opencode.json. Only providers
# used by a registry model are migrated. The default is a dry run that prints
# the plan and changes nothing. The plan is one JSON document, MIGRATE_PLAN:
#   {"providers":[{name,base_url,state,storage,env_ref,reason,entry}],
#    "models":[{id,request_body,context:{tokens,source}|null,deferred}]}
# state: new | pending | done | skip. storage: none env keyring plaintext
# stored skip ask.
#
# Secret rules: a literal apiKey is never printed, logged, put in a plan, in
# argv or copied anywhere but the chosen storage. It travels from opencode.json
# through a pipe to shunt_keyring_store / shunt_provider_plaintext_store.
# opencode.json is never modified.

MIGRATE_STORAGE_CHOICES="keyring env plaintext skip"
MIGRATE_PLAN=""
_MIGRATE_TMP=""

# _migrate_opencode_json
_migrate_opencode_json() { printf '%s' "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"; }

# _migrate_collect_providers
# Prints one compact JSON line per opencode provider used by the registry,
# with the key classified as none | env | literal (the key itself is dropped).
_migrate_collect_providers() {
  jq -c --slurpfile reg "$SHUNT_MODELS_FILE" '
    ([$reg[0].models[]?.id | split("/")[0]] | unique) as $used
    | (.provider // {}) | to_entries[] | select(.key as $k | $used | index($k))
    | (.value.options.apiKey // "") as $k
    | (if ($k | type) == "string" then ($k | capture("^\\{env:(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}$")? // null) else null end) as $env
    | {name: .key, base_url: (.value.options.baseURL // ""),
       key_kind: (if $k == "" then "none" elif $env != null then "env" else "literal" end),
       env_ref: ($env.n // "")}' "$(_migrate_opencode_json)"
}

# _migrate_default_env_ref <provider>
_migrate_default_env_ref() {
  printf 'SHUNT_%s_KEY' "$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' _)"
}

# _migrate_ask_storage <provider>
# Asks on the tty which storage to use for a literal key. Prints the choice.
_migrate_ask_storage() {
  local name="$1" default=env choice
  [ -z "$(shunt_keyring_backend)" ] || default=keyring
  read -r -p "Key storage for '$name' ($MIGRATE_STORAGE_CHOICES, default $default): " choice
  choice="${choice:-$default}"
  case " $MIGRATE_STORAGE_CHOICES " in
    *" $choice "*) printf '%s' "$choice" ;;
    *) echo "shunt: '$choice' is not a storage choice, skipping the key of '$name'." >&2; printf skip ;;
  esac
}

# _migrate_resolve_storage <provider> <kind> <apply 0|1> <flag>
# Prints the storage word for the provider's key, see the header.
_migrate_resolve_storage() {
  local name="$1" kind="$2" apply="$3" flag="$4" type storage
  case "$kind" in none) printf none; return ;; env) printf env; return ;; esac
  type=$(shunt_provider_key_type "$name" 2>/dev/null) || type=none
  if { [ "$type" = keyring ] || [ "$type" = plaintext ]; } && shunt_provider_key_resolve "$name" >/dev/null 2>&1; then
    printf stored; return
  fi
  if [ -n "$flag" ]; then
    storage="$flag"
  elif [ -t 0 ] && [ "$apply" = 1 ]; then
    storage=$(_migrate_ask_storage "$name")
  elif [ -t 0 ]; then
    printf ask; return
  else
    echo "shunt: provider '$name' has a literal key, no tty and no --key-storage: treating it as skip." >&2
    storage=skip
  fi
  if [ "$storage" = keyring ] && [ -z "$(shunt_keyring_backend)" ]; then
    echo "shunt: no keyring backend found, treating the key of '$name' as skip." >&2
    storage=skip
  fi
  printf '%s' "$storage"
}

# _migrate_entry <storage> <base_url> <env_ref>
# Prints the providers.json fields the migration sets for the provider.
_migrate_entry() {
  local storage="$1" base="$2" ref="$3"
  jq -n -c --arg s "$storage" --arg b "$base" --arg r "$ref" '
    if $s == "skip" or $s == "ask" then {transport: "opencode", base_url: $b, key: {type: "keyring"}}
    else {transport: "http", base_url: $b}
      + (if $s == "none" then {key: {type: "none"}}
         elif $s == "env" then {key: {type: "env", ref: $r}}
         elif $s == "keyring" or $s == "plaintext" then {key: {type: $s}}
         else {} end)
    end'
}

# _migrate_plan_provider <collected-json> <apply 0|1> <flag>
# Prints the plan entry for one provider.
_migrate_plan_provider() {
  local line="$1" apply="$2" flag="$3" name raw kind ref state=new storage=none reason="" base="" entry=null err
  name=$(jq -r .name <<<"$line"); raw=$(jq -r .base_url <<<"$line")
  kind=$(jq -r .key_kind <<<"$line"); ref=$(jq -r .env_ref <<<"$line")
  if [ "$(shunt_provider_transport "$name")" = http ]; then
    state=done; reason="already on the http transport"
  elif ! err=$(_shunt_http_check_base_url "$name" "$raw" _ 2>&1 >/dev/null); then
    state=skip; reason="${err#shunt: }"
  else
    _shunt_http_check_base_url "$name" "$raw" base 2>/dev/null
    storage=$(_migrate_resolve_storage "$name" "$kind" "$apply" "$flag")
    [ "$storage" != env ] || [ "$kind" = env ] || ref=$(_migrate_default_env_ref "$name")
    case "$storage" in skip | ask) state=pending ;; esac
    entry=$(_migrate_entry "$storage" "$base" "$ref")
  fi
  jq -n -c --arg n "$name" --arg b "$base" --arg st "$state" --arg s "$storage" --arg r "$ref" \
    --arg why "$reason" --argjson e "$entry" \
    '{name: $n, base_url: $b, state: $st, storage: $s, env_ref: $r, reason: $why, entry: $e}'
}

# _migrate_providers_doc
# Prints providers.json as it would be after the migration (existing entries
# kept, migrated ones merged in).
_migrate_providers_doc() {
  local base='{"version":1,"providers":{}}'
  [ ! -f "$SHUNT_PROVIDERS_FILE" ] || base=$(cat "$SHUNT_PROVIDERS_FILE")
  jq -c --argjson plan "$MIGRATE_PLAN" '
    reduce ($plan.providers[] | select(.entry != null)) as $p (.;
      .providers[$p.name] = ((.providers[$p.name] // {}) + $p.entry))' <<<"$base"
}

# _migrate_effort <id>
# Prints the model's reasoning effort: the registry thinking_options first,
# then the model's options in opencode.json.
_migrate_effort() {
  local id="$1"
  jq -r --arg id "$id" --arg p "${id%%/*}" --arg m "${id#*/}" \
    --slurpfile oc "$(_migrate_opencode_json)" '
    ((.models[] | select(.id == $id) | .thinking_options | objects | .reasoningEffort | strings)
      // ($oc[0].provider[$p].models[$m].options | objects | .reasoningEffort | strings)) // empty
    | select(length > 0)' "$SHUNT_MODELS_FILE"
}

# _migrate_context <id> <detect 0|1> <detect-providers-file>
# Prints "tokens<TAB>source", "deferred" (detection needs a key not stored yet
# and no fallback is claimed), or nothing when there is no number at all.
_migrate_context() {
  local id="$1" detect="$2" pfile="$3" tokens fallback
  if [ "$detect" = 1 ]; then
    tokens=$( (SHUNT_PROVIDERS_FILE="$pfile"; shunt_models_detect_context "$id") 2>/dev/null) || tokens=""
    if [ -n "$tokens" ]; then printf '%s\tdetected from the provider' "$tokens"; return; fi
  fi
  fallback=$(jq -r --arg p "${id%%/*}" --arg m "${id#*/}" \
    '.provider[$p].models[$m].limit.context | select(type == "number" and . > 0 and . == floor) | tostring' \
    "$(_migrate_opencode_json)" 2>/dev/null) || fallback=""
  [[ "$fallback" =~ ^[1-9][0-9]{0,11}$ ]] || return 0
  printf '%s\tfrom opencode.json, not verified' "$fallback"
}

# _migrate_plan_models <detect-all 0|1> <detect-providers-file>
# Prints the models part of the plan as a JSON array.
_migrate_plan_models() {
  local detect_all="$1" pfile="$2" id provider pstate storage detect out="[]" rb effort ctx tokens source deferred
  while IFS= read -r id; do
    provider="${id%%/*}"
    pstate=$(jq -r --arg p "$provider" '.providers[] | select(.name == $p) | .state + " " + .storage' <<<"$MIGRATE_PLAN")
    case "$pstate" in "new "* | "done "*) ;; *) continue ;; esac
    storage="${pstate#* }"; detect=1; deferred=false
    case "$storage" in keyring | plaintext) [ "$detect_all" = 1 ] || { detect=0; deferred=true; } ;; esac
    rb=null; ctx=null
    if jq -e --arg id "$id" '.models[] | select(.id == $id) | (.request_body // null) == null' "$SHUNT_MODELS_FILE" >/dev/null; then
      effort=$(_migrate_effort "$id")
      [ -z "$effort" ] || rb=$(jq -n -c --arg e "$effort" '{reasoning_effort: $e}')
    fi
    if jq -e --arg id "$id" '.models[] | select(.id == $id) | (.context_tokens // null) == null' "$SHUNT_MODELS_FILE" >/dev/null; then
      IFS=$'\t' read -r tokens source <<<"$(_migrate_context "$id" "$detect" "$pfile")" || true
      [ -z "$tokens" ] || ctx=$(jq -n -c --argjson t "$tokens" --arg s "$source" '{tokens: $t, source: $s}')
    fi
    out=$(jq -c --arg id "$id" --argjson rb "$rb" --argjson c "$ctx" --argjson d "$deferred" \
      '. + [{id: $id, request_body: $rb, context: $c, deferred: $d}]' <<<"$out")
  done < <(jq -r '.models[].id' "$SHUNT_MODELS_FILE")
  printf '%s' "$out"
}

# _migrate_models_doc
# Prints the registry as it would be after the migration.
_migrate_models_doc() {
  jq -c --argjson plan "$MIGRATE_PLAN" '
    ($plan.models | map({(.id): .}) | add // {}) as $by
    | .models |= map(($by[.id]) as $p
      | if $p == null then . else
          (if $p.request_body != null and (.request_body // null) == null then .request_body = $p.request_body else . end)
          | (if $p.context != null and (.context_tokens // null) == null then .context_tokens = $p.context.tokens else . end)
        end)' "$SHUNT_MODELS_FILE"
}

# _migrate_print_provider <plan-entry-json>
_migrate_print_provider() {
  jq -r '
    "provider \(.name): " + (
      if .state == "skip" then "skipped, \(.reason)"
      elif .state == "done" then "\(.reason), nothing to do for the provider"
      else "base_url \(.base_url), transport opencode -> \(if .state == "pending" then "opencode (stays, key pending)" else "http" end), key: " + (
        if .storage == "none" then "none (opencode.json has no apiKey)"
        elif .storage == "env" then "env \(.env_ref) (export it yourself, the key is not copied)"
        elif .storage == "keyring" then "copied to the keyring (never shown)"
        elif .storage == "plaintext" then "copied to providers.json as plain text (mode 600, never shown)"
        elif .storage == "stored" then "already stored"
        elif .storage == "ask" then "literal key, storage is asked at --apply (or pass --key-storage keyring|env|plaintext|skip)"
        else "skipped: run `! scripts/shunt-models key set \(.name)` then re-run" end)
      end)' <<<"$1"
}

# _migrate_print_plan
_migrate_print_plan() {
  local line
  while IFS= read -r line; do _migrate_print_provider "$line"; done < <(jq -c '.providers[]' <<<"$MIGRATE_PLAN")
  jq -r '.models[] |
    "  model \(.id): request_body " + (if .request_body == null then "unchanged" else "\(.request_body | tojson) (from reasoningEffort)" end)
    + ", context_tokens " + (if .context != null then "\(.context.tokens) (\(.context.source))"
      elif .deferred then "detected at --apply, else the opencode.json limit (not verified)" else "unchanged" end)' <<<"$MIGRATE_PLAN"
}

# _migrate_backup <file>
_migrate_backup() {
  [ -f "$1" ] || return 0
  (umask 077 && cp "$1" "$1.bak-$_MIGRATE_STAMP")
  echo "shunt: backup: $1.bak-$_MIGRATE_STAMP"
}

# _migrate_store_keys <storage>
# Stores the literal key of every provider planned with <storage>, keyring
# (before providers.json is written) or plaintext (after). A failed keyring
# store turns the provider into pending. The key goes through a pipe only.
_migrate_store_keys() {
  local which="$1" name
  while IFS= read -r name; do
    if [ "$which" = keyring ]; then
      if jq -r --arg p "$name" '.provider[$p].options.apiKey' "$(_migrate_opencode_json)" | shunt_keyring_store "$name"; then
        continue
      fi
      echo "shunt: could not store the key of '$name' in the keyring, leaving it pending." >&2
      MIGRATE_PLAN=$(jq -c --arg n "$name" '(.providers[] | select(.name == $n)) |= (.storage = "skip" | .state = "pending"
        | .entry = {transport: "opencode", base_url: .base_url, key: {type: "keyring"}})' <<<"$MIGRATE_PLAN")
    else
      jq -r --arg p "$name" '.provider[$p].options.apiKey' "$(_migrate_opencode_json)" | shunt_provider_plaintext_store "$name" \
        || shunt_report_error "could not store the key of '$name' in $SHUNT_PROVIDERS_FILE."
      shunt_provider_plaintext_warning
    fi
  done < <(jq -r --arg s "$which" '.providers[] | select(.storage == $s and .state == "new") | .name' <<<"$MIGRATE_PLAN")
}

# _migrate_apply
_migrate_apply() {
  _MIGRATE_STAMP=$(date +%Y%m%d%H%M%S)
  _migrate_backup "$SHUNT_MODELS_FILE"
  _migrate_backup "$SHUNT_PROVIDERS_FILE"
  _migrate_store_keys keyring
  shunt_providers_write "$(_migrate_providers_doc)" || shunt_report_error "could not write $SHUNT_PROVIDERS_FILE."
  _migrate_store_keys plaintext
  MIGRATE_PLAN=$(jq -c --argjson m "$(_migrate_plan_models 1 "$SHUNT_PROVIDERS_FILE")" '.models = $m' <<<"$MIGRATE_PLAN")
  shunt_models_write "$(_migrate_models_doc)"
  echo "shunt: migration applied. Check with: shunt-models status"
}

# _migrate_build_plan <apply 0|1> <flag>
_migrate_build_plan() {
  local apply="$1" flag="$2" line providers="[]" entry names tmp
  while IFS= read -r line; do
    entry=$(_migrate_plan_provider "$line" "$apply" "$flag")
    providers=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$providers")
  done < <(_migrate_collect_providers)
  MIGRATE_PLAN=$(jq -n -c --argjson p "$providers" '{providers: $p, models: []}')
  # Detection sees the planned providers, without any literal key: a temp
  # providers file with only the migrated entries, removed right away.
  names=$(jq -c '[.providers[] | select(.state == "new" or .state == "done") | .name]' <<<"$MIGRATE_PLAN")
  tmp=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-migrate.XXXXXX")
  _migrate_providers_doc | jq -c --argjson n "$names" '.providers |= with_entries(select(.key | IN($n[])))' >"$tmp"
  MIGRATE_PLAN=$(jq -c --argjson m "$(_migrate_plan_models 0 "$tmp")" '.models = $m' <<<"$MIGRATE_PLAN")
  rm -f "$tmp"
}

# _migrate_has_changes
_migrate_has_changes() {
  local old_p='{"version":1,"providers":{}}'
  [ ! -f "$SHUNT_PROVIDERS_FILE" ] || old_p=$(cat "$SHUNT_PROVIDERS_FILE")
  [ "$(jq -S -c . <<<"$old_p")" != "$(_migrate_providers_doc | jq -S -c .)" ] \
    || [ "$(jq -S -c . "$SHUNT_MODELS_FILE")" != "$(_migrate_models_doc | jq -S -c .)" ]
}

# cmd_migrate_from_opencode [--apply] [--key-storage keyring|env|plaintext|skip]
cmd_migrate_from_opencode() {
  local apply=0 flag="" answer
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --key-storage)
        [ -n "${2:-}" ] && case " $MIGRATE_STORAGE_CHOICES " in *" $2 "*) true ;; *) false ;; esac \
          || shunt_report_error "--key-storage takes one of: $MIGRATE_STORAGE_CHOICES."
        flag="$2"; shift 2 ;;
      *) shunt_report_error "usage: shunt-models --migrate-from-opencode [--apply] [--key-storage $(echo "$MIGRATE_STORAGE_CHOICES" | tr ' ' '|')]" ;;
    esac
  done
  shunt_models_available || shunt_report_error "no models registry at $SHUNT_MODELS_FILE."
  [ -f "$(_migrate_opencode_json)" ] || shunt_report_error "no $(_migrate_opencode_json) to migrate from."
  shunt_providers_validate || exit 1
  _migrate_build_plan "$apply" "$flag"
  if ! _migrate_has_changes; then
    _migrate_print_plan
    echo "shunt: nothing to migrate, nothing to do."
    return 0
  fi
  [ "$apply" = 1 ] && echo "shunt: migration plan" || echo "shunt: migration plan (dry run, nothing is changed)"
  _migrate_print_plan
  if [ "$apply" != 1 ]; then
    echo "shunt: re-run with --apply to write it (a backup of models.json and providers.json is made first)."
    return 0
  fi
  if [ -t 0 ]; then
    read -r -p "Proceed? [y/N] " answer
    case "$answer" in y | Y | yes | YES) ;; *) echo "shunt: aborted, nothing changed."; return 0 ;; esac
  fi
  _migrate_apply
}
