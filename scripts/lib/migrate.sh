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
# Nothing else lives here: the opencode provider classification the dashboard
# needs is migrate_plan.collect_providers.

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
