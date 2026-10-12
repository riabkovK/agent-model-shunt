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
# Key sources, in order: the apiKey of the provider in opencode.json (a literal
# string, {env:NAME} or {file:path}), else the provider's entry in OpenCode's
# auth.json ($XDG_DATA_HOME/opencode/auth.json, default
# ~/.local/share/opencode/auth.json, {"<provider>":{"type":"api","key":"..."}}).
# A literal, a file or an auth.json key is copied to the chosen storage.
#
# Secret rules: such a key is never printed, logged, put in a plan, in argv or
# copied anywhere but the chosen storage. It travels from its source through a
# pipe to shunt_keyring_store / shunt_provider_plaintext_store. The detection
# providers file in TMPDIR never holds a key. opencode.json and auth.json are
# never modified.

MIGRATE_STORAGE_CHOICES="keyring env plaintext skip"
MIGRATE_PLAN=""
_MIGRATE_DETECT_TMP=""
_MIGRATE_USED_REFS=""
# Env var through which the detection subshell hands one stored plaintext key
# to the sanitized detection providers file (see _migrate_detect_doc).
_MIGRATE_DETECT_KEY_VAR="SHUNT_MIGRATE_DETECT_KEY"

# _migrate_opencode_json
_migrate_opencode_json() { printf '%s' "$SHUNT_OPENCODE_CONFIG_HOME/opencode.json"; }

# _migrate_collect_providers
# Prints one compact JSON line per opencode provider used by the registry,
# with the key classified as none | env | file | literal (a literal key itself
# is dropped, a file key keeps its path).
_migrate_collect_providers() {
  jq -c --arg name_re "$SHUNT_PROVIDER_NAME_REGEX_JQ" --slurpfile reg "$SHUNT_MODELS_FILE" '
    ([$reg[0].models[]?.id | split("/")[0]] | unique) as $used
    | (.provider // {}) | to_entries[] | select(.key as $k | $used | index($k))
    | (.value.options.apiKey // "") as $raw
    | (if ($raw | type) == "string" then $raw else "" end) as $k
    | (if ($k | type) == "string" then ($k | capture("^\\{env:(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}$")? // null) else null end) as $env
    | (if ($k | type) == "string" then ($k | capture("^\\{file:(?<p>.+)\\}$")? // null) else null end) as $file
    | {name: .key, bad_name: (.key | test($name_re) | not), base_url: (.value.options.baseURL // ""),
       bad_key: ($raw | type) != "string" and $raw != "",
       key_kind: (if $k == "" then "none" elif $env != null then "env" elif $file != null then "file" else "literal" end),
       env_ref: ($env.n // ""), key_path: ($file.p // "")}' "$(_migrate_opencode_json)"
}

# _migrate_auth_json
_migrate_auth_json() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"; }

# _migrate_trim: strips leading and trailing whitespace from the argument.
_migrate_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# _migrate_expand_path <path>
# Expands a leading ~ and resolves a relative path against the OpenCode config dir.
_migrate_expand_path() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s' "$SHUNT_OPENCODE_CONFIG_HOME/$1" ;;
  esac
}

# _migrate_auth_json_has_key <provider>
# Succeeds when auth.json holds a non-empty api key for the provider.
_migrate_auth_json_has_key() {
  local f
  f=$(_migrate_auth_json)
  [ -f "$f" ] && [ -r "$f" ] || return 1
  jq -e --arg p "$1" '.[$p] | objects | .type == "api" and (.key | type) == "string" and (.key | gsub("^\\s+|\\s+$"; "") | length) > 0' "$f" >/dev/null 2>&1
}

# _migrate_file_key_ok <path>
# Succeeds when the {file:path} key file is readable and holds a non-blank key
# without a line break inside it.
_migrate_file_key_ok() {
  local f key
  f=$(_migrate_expand_path "$1")
  [ -f "$f" ] && [ -r "$f" ] || return 1
  key=$(_migrate_trim "$(cat "$f" 2>/dev/null)")
  _migrate_key_usable "$key"
}

# _migrate_key_usable <trimmed-key>
# Succeeds when the key is not empty and has no line break inside it.
_migrate_key_usable() {
  case "$1" in '' | *$'\n'* | *$'\r'*) return 1 ;; esac
}

# _migrate_read_key <provider>
# Prints the key the plan copies for the provider, from its source. Only ever
# captured into a variable or piped into a storage function.
_migrate_read_key() {
  local name="$1" src path key=""
  src=$(jq -r --arg n "$name" '.providers[] | select(.name == $n) | .key_source' <<<"$MIGRATE_PLAN")
  case "$src" in
    literal) key=$(jq -r --arg p "$name" '.provider[$p].options.apiKey' "$(_migrate_opencode_json)") ;;
    file)
      path=$(jq -r --arg n "$name" '.providers[] | select(.name == $n) | .key_path' <<<"$MIGRATE_PLAN")
      key=$(_migrate_trim "$(cat "$(_migrate_expand_path "$path")")") || return 1
      _migrate_key_usable "$key" || return 1 ;;
    auth.json)
      key=$(_migrate_trim "$(jq -r --arg p "$name" '.[$p].key' "$(_migrate_auth_json)")") || return 1
      _migrate_key_usable "$key" || return 1 ;;
  esac
  printf '%s\n' "$key"
}

# _migrate_base_env_ref <provider>
_migrate_base_env_ref() {
  printf 'SHUNT_%s_KEY' "$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' _)"
}

# _migrate_default_env_ref <provider>
# Prints SHUNT_<NAME>_KEY, with a _2, _3, ... suffix while that ref is already
# used by another provider (a-b and a.b would otherwise share one variable).
_migrate_default_env_ref() {
  local base ref n=1
  base=$(_migrate_base_env_ref "$1")
  ref="$base"
  while [[ $'\n'"$_MIGRATE_USED_REFS" == *$'\n'"$ref"$'\n'* ]]; do
    n=$((n + 1)); ref="${base}_$n"
  done
  printf '%s' "$ref"
}

# _migrate_ask_storage <provider>
# Asks on the tty which storage to use for a key to copy. Prints the choice.
_migrate_ask_storage() {
  local name="$1" default=env choice
  [ -z "$(shunt_keyring_backend)" ] || default=keyring
  read -r -p "Key storage for '$name' ($MIGRATE_STORAGE_CHOICES, default $default): " choice
  choice="${choice:-$default}"
  if shunt_word_in_list "$choice" "$MIGRATE_STORAGE_CHOICES"; then
    printf '%s' "$choice"
  else
    echo "shunt: '$choice' is not a storage choice, skipping the key of '$name'." >&2
    printf skip
  fi
}

# _migrate_resolve_storage <provider> <kind> <apply 0|1> <flag>
# Prints the storage word for the provider's key, see the header.
_migrate_resolve_storage() {
  local name="$1" kind="$2" apply="$3" flag="$4" type storage
  case "$kind" in none) printf none; return ;; env) printf env; return ;; esac
  # Any other kind (literal, file, auth.json) is a key to copy.
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
    echo "shunt: provider '$name' has a key to copy, no tty and no --key-storage: treating it as skip." >&2
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

# _migrate_key_source <provider> <kind> <path>
# Prints the source of the key to copy (literal, file, auth.json) or nothing.
# Fails with a reason on stderr when the source is unusable.
_migrate_key_source() {
  local name="$1" kind="$2" path="$3"
  case "$kind" in
    literal) printf literal ;;
    file)
      _migrate_file_key_ok "$path" \
        || { echo "the apiKey file $path is not readable or is empty, so the key cannot be copied" >&2; return 1; }
      printf file ;;
    none)
      if _migrate_auth_json_has_key "$name"; then printf auth.json; fi ;;
  esac
}

# _migrate_plan_provider <collected-json> <apply 0|1> <flag>
# Prints the plan entry for one provider.
_migrate_plan_provider() {
  local line="$1" apply="$2" flag="$3" name raw kind ref state=new storage=none reason="" base="" entry=null err
  local path source="" bad_note=""
  name=$(jq -r .name <<<"$line"); raw=$(jq -r .base_url <<<"$line")
  kind=$(jq -r .key_kind <<<"$line"); ref=$(jq -r .env_ref <<<"$line"); path=$(jq -r .key_path <<<"$line")
  [ "$(jq -r .bad_key <<<"$line")" != true ] \
    || bad_note="the apiKey in opencode.json is not a string, so it is not imported as a key"
  if [ "$(jq -r .bad_name <<<"$line")" = true ]; then
    state=skip; reason="the provider name has characters other than letters, digits, dot, dash and underscore, so it stays on opencode"
  elif [ "$(shunt_provider_transport "$name")" = http ]; then
    state=done; reason="already on the http transport"
  elif ! err=$(_shunt_http_check_base_url "$name" "$raw" _ 2>&1 >/dev/null); then
    state=skip; reason="${err#shunt: }"
  elif ! err=$(_migrate_key_source "$name" "$kind" "$path" 2>&1 >/dev/null); then
    state=skip; reason="$err, the provider stays on opencode"
  else
    source=$(_migrate_key_source "$name" "$kind" "$path")
    [ -z "$source" ] || kind=literal
    _shunt_http_check_base_url "$name" "$raw" base 2>/dev/null
    storage=$(_migrate_resolve_storage "$name" "$kind" "$apply" "$flag")
    if [ "$storage" = env ] && [ "$kind" != env ]; then
      ref=$(_migrate_default_env_ref "$name")
      [ "$ref" = "$(_migrate_base_env_ref "$name")" ] \
        || reason="the default env ref is taken by another provider, so this one gets $ref"
    fi
    case "$storage" in skip | ask) state=pending ;; esac
    entry=$(_migrate_entry "$storage" "$base" "$ref")
  fi
  # Nothing is imported for a provider already on http, so the note is moot there.
  if [ -n "$bad_note" ] && [ "$state" != done ]; then
    case "$reason" in
      "") reason="$bad_note" ;;
      *[.!?]) reason="$reason $bad_note" ;;
      *) reason="$reason. $bad_note" ;;
    esac
  fi
  jq -n -c --arg n "$name" --arg b "$base" --arg st "$state" --arg s "$storage" --arg r "$ref" \
    --arg why "$reason" --argjson e "$entry" --arg src "$source" --arg kp "$path" \
    '{name: $n, base_url: $b, state: $st, storage: $s, env_ref: $r, reason: $why, entry: $e,
      key_source: $src, key_path: $kp}'
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

# _migrate_detect_env <detect-providers-file> <provider>
# Run in the detection subshell. When the detection file is the sanitized copy
# (see _migrate_detect_doc), hands the provider's stored plaintext key over in
# the environment of that subshell only, never through a file.
_migrate_detect_env() {
  local pfile="$1" provider="$2" key
  [ "$pfile" != "$SHUNT_PROVIDERS_FILE" ] || return 0
  [ -f "$SHUNT_PROVIDERS_FILE" ] || return 0
  key=$(jq -r --arg p "$provider" '.providers[$p] | select(.key.type == "plaintext") | .key.ref // empty' "$SHUNT_PROVIDERS_FILE" 2>/dev/null) || return 0
  [ -z "$key" ] || export "$_MIGRATE_DETECT_KEY_VAR=$key"
}

# _migrate_context <id> <detect 0|1> <detect-providers-file>
# Prints "tokens<TAB>source", or nothing when there is no number at all.
_migrate_context() {
  local id="$1" detect="$2" pfile="$3" tokens fallback
  if [ "$detect" = 1 ]; then
    tokens=$( (_migrate_detect_env "$pfile" "${id%%/*}"; SHUNT_PROVIDERS_FILE="$pfile"; shunt_models_detect_context "$id") 2>/dev/null) || tokens=""
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
  jq -r --arg cmd "$SHUNT_MODELS_HINT_CMD" '
    "provider \(.name): " + (
      if .state == "skip" then "skipped, \(.reason)"
      elif .state == "done" then "\(.reason), nothing to do for the provider"
      else "base_url \(.base_url), transport opencode -> \(if .state == "pending" then "opencode (stays, key pending)" else "http" end), key: " + (
        (if .key_source == "file" then "read from the apiKey file \(.key_path) (never shown), then "
         elif .key_source == "auth.json" then "read from OpenCode auth.json (never shown), then "
         else "" end)
        + (if .storage == "none" then "none (no apiKey in opencode.json or auth.json)"
        elif .storage == "env" then "env \(.env_ref) (export it yourself, the key is not copied)"
          + (if .reason != "" then " [\(.reason)]" else "" end)
        elif .storage == "keyring" then "copied to the keyring (never shown)"
        elif .storage == "plaintext" then "copied to providers.json as plain text (mode 600, never shown)"
        elif .storage == "stored" then "already stored"
        elif .storage == "ask" then "key to copy, storage is asked at --apply (or pass --key-storage keyring|env|plaintext|skip)"
        else "skipped: run `! \($cmd) key set \(.name)` then re-run" end))
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
# Stores the key (see _migrate_read_key) of every provider planned with <storage>, keyring
# (before providers.json is written) or plaintext (after). A failed keyring
# store turns the provider into pending. The key goes through a pipe only.
_migrate_store_keys() {
  local which="$1" name
  while IFS= read -r name; do
    if [ "$which" = keyring ]; then
      if _migrate_read_key "$name" | shunt_keyring_store "$name"; then
        continue
      fi
      echo "shunt: could not store the key of '$name' in the keyring, leaving it pending." >&2
      MIGRATE_PLAN=$(jq -c --arg n "$name" '(.providers[] | select(.name == $n)) |= (.storage = "skip" | .state = "pending"
        | .entry = {transport: "opencode", base_url: .base_url, key: {type: "keyring"}})' <<<"$MIGRATE_PLAN")
    else
      _migrate_read_key "$name" | shunt_provider_plaintext_store "$name" \
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
  shunt_providers_lock || shunt_report_error "could not lock $SHUNT_PROVIDERS_FILE."
  shunt_providers_write "$(_migrate_providers_doc)" || shunt_report_error "could not write $SHUNT_PROVIDERS_FILE."
  _migrate_store_keys plaintext
  shunt_providers_unlock
  MIGRATE_PLAN=$(jq -c --argjson m "$(_migrate_plan_models 1 "$SHUNT_PROVIDERS_FILE")" '.models = $m' <<<"$MIGRATE_PLAN")
  shunt_models_write "$(_migrate_models_doc)"
  echo "shunt: migration applied. Check with: $SHUNT_MODELS_HINT_CMD status"
}

# _migrate_build_plan <apply 0|1> <flag>
_migrate_build_plan() {
  local apply="$1" flag="$2" line providers="[]" entry names
  # Env refs already taken: those in providers.json, every {env:NAME} of any
  # opencode provider (migrated or not) and those the plan hands out.
  _MIGRATE_USED_REFS=$(jq -r '(.provider // {}) | .[] | objects | .options.apiKey? | strings
    | capture("^\\{env:(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}$")? | .n' "$(_migrate_opencode_json)" 2>/dev/null || true)
  _MIGRATE_USED_REFS+=$'\n'
  if [ -f "$SHUNT_PROVIDERS_FILE" ]; then
    _MIGRATE_USED_REFS+=$(jq -r '.providers[]? | .key | objects | select(.type == "env") | .ref // empty' "$SHUNT_PROVIDERS_FILE" 2>/dev/null || true)
    _MIGRATE_USED_REFS+=$'\n'
  fi
  while IFS= read -r line; do
    entry=$(_migrate_plan_provider "$line" "$apply" "$flag")
    providers=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$providers")
    _MIGRATE_USED_REFS+=$(jq -r 'select(.storage == "env") | .env_ref' <<<"$entry")$'\n'
  done < <(_migrate_collect_providers)
  MIGRATE_PLAN=$(jq -n -c --argjson p "$providers" '{providers: $p, models: []}')
  # Detection sees the planned providers through a temp providers file that
  # holds no key (see _migrate_detect_doc). It is removed on every way out.
  names=$(jq -c '[.providers[] | select(.state == "new" or .state == "done") | .name]' <<<"$MIGRATE_PLAN")
  _MIGRATE_DETECT_TMP=""
  _shunt_guard_install _MIGRATE_G _migrate_detect_cleanup
  _MIGRATE_DETECT_TMP=$(umask 077 && mktemp "${TMPDIR:-/tmp}/shunt-migrate.XXXXXX") \
    || { _shunt_guard_remove _MIGRATE_G; shunt_report_error "cannot create a temp file in ${TMPDIR:-/tmp}."; }
  _migrate_detect_doc "$names" >"$_MIGRATE_DETECT_TMP"
  MIGRATE_PLAN=$(jq -c --argjson m "$(_migrate_plan_models 0 "$_MIGRATE_DETECT_TMP")" '.models = $m' <<<"$MIGRATE_PLAN")
  _migrate_detect_cleanup
  _shunt_guard_remove _MIGRATE_G
}

# _migrate_detect_doc <provider-names-json>
# Prints the providers document used for context detection: the planned
# providers only, and every stored plaintext key replaced by an env ref to
# _MIGRATE_DETECT_KEY_VAR, so no key is ever written to a temp file.
_migrate_detect_doc() {
  _migrate_providers_doc | jq -c --argjson n "$1" --arg v "$_MIGRATE_DETECT_KEY_VAR" '
    .providers |= with_entries(select(.key | IN($n[])))
    | .providers |= map_values(if .key.type == "plaintext" and ((.key.ref // "") != "")
        then .key = {type: "env", ref: $v} else . end)'
}

# _migrate_detect_cleanup
_migrate_detect_cleanup() {
  [ -z "$_MIGRATE_DETECT_TMP" ] || rm -f "$_MIGRATE_DETECT_TMP"
  _MIGRATE_DETECT_TMP=""
}

# _migrate_has_changes
_migrate_has_changes() {
  local old_p='{"version":1,"providers":{}}'
  [ ! -f "$SHUNT_PROVIDERS_FILE" ] || old_p=$(cat "$SHUNT_PROVIDERS_FILE")
  [ "$(jq -S -c . <<<"$old_p")" != "$(_migrate_providers_doc | jq -S -c .)" ] \
    || [ "$(jq -S -c . "$SHUNT_MODELS_FILE")" != "$(_migrate_models_doc | jq -S -c .)" ]
}

# cmd_migrate_from_opencode [--apply [--yes]] [--key-storage keyring|env|plaintext|skip]
cmd_migrate_from_opencode() {
  local apply=0 yes=0 flag="" answer
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --yes) yes=1; shift ;;
      --key-storage)
        [ -n "${2:-}" ] && shunt_word_in_list "$2" "$MIGRATE_STORAGE_CHOICES" \
          || shunt_report_error "--key-storage takes one of: $MIGRATE_STORAGE_CHOICES."
        flag="$2"; shift 2 ;;
      *) shunt_report_error "usage: shunt-models --migrate-from-opencode [--apply [--yes]] [--key-storage $(echo "$MIGRATE_STORAGE_CHOICES" | tr ' ' '|')]" ;;
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
  if [ "$yes" != 1 ]; then
    if [ ! -t 0 ]; then
      echo "shunt: refusing to apply without a terminal or --yes. Show the dry-run plan above to the user, and re-run with --apply --yes after they confirm." >&2
      exit 1
    fi
    read -r -p "Proceed? [y/N] " answer
    case "$answer" in y | Y | yes | YES) ;; *) echo "shunt: aborted, nothing changed."; return 0 ;; esac
  fi
  _migrate_apply
}
