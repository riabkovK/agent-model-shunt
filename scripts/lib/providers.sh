#!/bin/bash
# What bash still needs of the provider config: shunt-key-dialog (phase P5 of the
# bash retirement) validates a provider name, reads its key type and prints the
# plaintext warning. Everything else (validation, listing, field getters, the
# base_url check, the keyring, key resolution, `provider set`, `key set`) lives in
# scripts/py/shunt/ (providers.py, providers_write.py, models_cli.py).
#
# Secret rule: no function here handles a key. Functions report problems on
# stderr and return non-zero, they never exit, so they are safe inside $(...).

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

SHUNT_PROVIDERS_FILE="${SHUNT_PROVIDERS_FILE:-$HOME/.config/agent-model-shunt/providers.json}"
SHUNT_PROC_VERSION_FILE="${SHUNT_PROC_VERSION_FILE:-/proc/version}"
# The one provider name charset. Names reach shell hints the user copies.
# Bash ERE's $ only matches at the very end, so "ok\n" is refused here. Python
# (providers.py) matches the same set of names.
SHUNT_PROVIDER_NAME_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# shunt_provider_name_ok <name>
shunt_provider_name_ok() { [[ "$1" =~ $SHUNT_PROVIDER_NAME_REGEX ]]; }

# shunt_provider_name_refuse <name>
# Explains on stderr why the name is refused. When providers.json already holds
# an entry under that name, says so and what to do. The name is shown through
# JSON string quoting, so it is quoted and has no raw control characters.
# The message is built by `shunt_py probe provider-name-refusal`.
shunt_provider_name_refuse() {
  SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" shunt_py probe provider-name-refusal -- "$1" >&2
}

# shunt_provider_key_type <provider>
# Prints the key type of the provider, or none when it is unset. Validates the
# whole file first and fails with its message.
shunt_provider_key_type() {
  SHUNT_PROVIDERS_FILE="$SHUNT_PROVIDERS_FILE" SHUNT_PROC_VERSION_FILE="$SHUNT_PROC_VERSION_FILE" \
    shunt_py providers field key-type -- "$1"
}

# shunt_provider_plaintext_warning
shunt_provider_plaintext_warning() {
  echo "shunt: warning: the key is stored in plain text in $SHUNT_PROVIDERS_FILE (mode 600). Prefer a keyring or an environment variable."
}

# Absolute, shell-quoted path of shunt-models for user-facing hints. Plugin users
# run from their own project, so a relative scripts/shunt-models would not resolve.
printf -v SHUNT_MODELS_HINT_CMD '%q' \
  "$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/shunt-models"
