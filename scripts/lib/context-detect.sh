# Context window auto-detection for models of an HTTP-transport provider.
# Meant to be sourced by scripts/shunt-models after opencode.sh (which brings
# providers.sh).
#
# The logic (the three sources, the 401/403 handling, the size cap and the
# request itself) lives in scripts/py/shunt/context_detect.py and
# scripts/py/shunt/httpclient.py. Neither curl nor jq is needed, the key stays in
# the memory of the Python process and is never in argv or in a file.
#
# Only what the provider itself reports is used, a number is never guessed from
# built-in knowledge. Every failure (network, non-2xx, bad JSON) just means "not
# found", except a 401 or 403 answer: that is reported apart (status
# SHUNT_DETECT_AUTH_FAILED), because the fix is a new key, not a hand-typed number.

# shellcheck source=py.sh
source "${BASH_SOURCE[0]%/*}/py.sh"

SHUNT_DETECT_TIMEOUT_SECONDS="${SHUNT_DETECT_TIMEOUT_SECONDS:-15}"
# Exit status of shunt_models_detect_context when the provider answered 401 or 403.
SHUNT_DETECT_AUTH_FAILED=3

# shunt_models_detect_context <provider/model>
# Prints the context window in tokens as reported by the provider. Fails with
# status 1 and prints nothing on stdout when it cannot find one, and with
# status SHUNT_DETECT_AUTH_FAILED (3) when the provider rejected the key.
# The providers file and timeout are passed per call: callers set them as
# unexported shell variables.
shunt_models_detect_context() {
  SHUNT_PROVIDERS_FILE="${SHUNT_PROVIDERS_FILE:-}" SHUNT_PROC_VERSION_FILE="${SHUNT_PROC_VERSION_FILE:-}" \
    SHUNT_DETECT_TIMEOUT_SECONDS="$SHUNT_DETECT_TIMEOUT_SECONDS" \
    shunt_py context detect -- "$1"
}
