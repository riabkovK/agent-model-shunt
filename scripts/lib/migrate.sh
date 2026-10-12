#!/bin/bash
# Migration from the OpenCode config to the HTTP transport:
# `shunt-models --migrate-from-opencode [--apply] [--key-storage <how>]`.
# Meant to be sourced by scripts/shunt-models after opencode.sh, models.sh,
# providers.sh and context-detect.sh.
#
# The migration itself (plan, dry run, prompts, backups, key storage, writes,
# context detection, the providers lock) is scripts/py/shunt/migrate.py with
# migrate_plan.py and migrate_view.py.
#
# What stays here is the jq classification of the opencode providers that
# scripts/lib/dashboard.sh still uses (_migrate_opencode_json and
# _migrate_collect_providers), until the dashboard is ported.

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

# cmd_migrate_from_opencode [--apply [--yes]] [--key-storage keyring|env|plaintext|skip]
# Exits with the status of the Python command when it is not 0 (errors are
# `shunt:` lines, as shunt_report_error printed them). The paths resolved by
# the bash libraries are passed for this call only, since they may be
# unexported shell defaults. Standard input stays the caller's, so the prompts
# still read the terminal. No key is passed here: Python reads the sources.
cmd_migrate_from_opencode() {
  SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" SHUNT_MODELS_FILE="$SHUNT_MODELS_FILE" \
    SHUNT_OPENCODE_CONFIG_HOME="$SHUNT_OPENCODE_CONFIG_HOME" SHUNT_PROC_VERSION_FILE="$SHUNT_PROC_VERSION_FILE" \
    SHUNT_PROVIDERS_LOCK_TIMEOUT="$SHUNT_PROVIDERS_LOCK_TIMEOUT" SHUNT_MODELS_HINT_CMD="$SHUNT_MODELS_HINT_CMD" \
    shunt_py migrate -- "$@" || exit $?
}
