# Transport layer: how a delegated call reaches a model, behind one normalized
# response format. Every transport yields the path to one JSON file per
# successful call:
#
#   {"text": string, "finish_reason": string,
#    "usage": {"input": int, "output": int},   # absent if none was reported
#    "cost": number}          # cost only when the provider reported it
#
# The usage log reads only this format, so a new transport only has to produce
# it. `opencode` (the OpenCode CLI) is the
# default, `http` posts straight to an OpenAI-compatible API. The transport is
# chosen per provider.
#
# The work lives in scripts/py/shunt: transport.py (dispatch), opencode_cli.py
# (the CLI transport: size guard, isolated config, child process and timeout,
# normalizing the transcript), transport_http.py (the HTTP transport) and
# failover.py (the loop over the candidate models). This file only holds the
# timeout default and the SHUNT_TRY_INVOKE_* statuses the bats tests compare
# against. Meant to be sourced by opencode.sh.

# One OpenCode CLI request is limited to SHUNT_TIMEOUT_SECONDS (GNU timeout
# syntax, 0 is no limit). SHUNT_TOTAL_TIMEOUT_SECONDS (http transport only) is
# the deadline for one model attempt, every chunk and merge request of a
# chunked call included. It is per model, not per delegated call: when a model
# fails over, the next candidate starts with a fresh deadline of its own. When
# unset it is three times SHUNT_TIMEOUT_SECONDS (no total deadline when that is
# 0), see scripts/py/shunt/deadline.py.
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-300}"

# Exit statuses of a transport call that name the failure, so the failover
# loop can say why a model failed. Every failure a transport knows
# about has one of the statuses below and is explained on stderr. Any other
# non-zero status (1) is unexpected. Keep them in step with transport_reply.py.
SHUNT_TRY_INVOKE_TIMEOUT=124
SHUNT_TRY_INVOKE_ERROR=2
SHUNT_TRY_INVOKE_EMPTY=3
# The provider rejected the key (HTTP 401/403). Not the model's fault, so the
# failover loop moves on to the next candidate without a breaker failure.
SHUNT_TRY_INVOKE_AUTH=4
# The http transport's total deadline (SHUNT_TOTAL_TIMEOUT_SECONDS) ended the
# call, as opposed to one request running past SHUNT_TIMEOUT_SECONDS (TIMEOUT).
SHUNT_TRY_INVOKE_DEADLINE=5
# The input is too large for this model, nothing was sent. Not the model's
# fault either: the failover loop tries the next candidate without a breaker
# failure, and when no candidate can take the input, Claude reads it itself.
SHUNT_TRY_INVOKE_OVERSIZE=6
# A config problem of this model (missing or unresolvable key, invalid base_url,
# request_body, oversize policy or total timeout, missing context_tokens or role
# prompt, an unusable providers.json or opencode agent). Nothing was sent and it says nothing about the model's health, so the
# failover loop explains it, tries the next candidate and records no breaker failure.
SHUNT_TRY_INVOKE_CONFIG=7

_SHUNT_TRANSPORT_LIB_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=providers.sh
source "$_SHUNT_TRANSPORT_LIB_DIR/providers.sh"
# shellcheck source=py.sh
source "$_SHUNT_TRANSPORT_LIB_DIR/py.sh"
unset _SHUNT_TRANSPORT_LIB_DIR
