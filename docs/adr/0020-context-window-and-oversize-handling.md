# 0020: Context window from detection or the user, and `map_reduce` or `fail` for oversize input

## Status

Accepted

## Context

`opencode -f` silently truncated large files (observed at 2000 lines), so the
model answered about part of the file without saying so. The `http` transport
([ADR 0018](0018-direct-http-transport-alongside-opencode.md)) sends the content
itself, so it must know how much a model can take, and must never truncate
silently.

## Decision

- `context_tokens` is a per-model registry field. It comes from auto-detection
  (`scripts/lib/context-detect.sh`, asks the provider, e.g. Ollama `/api/show`
  or a `max_model_len` style field) or from `shunt-models set-context`. It is
  never guessed. A model without it is only trusted with small requests, and a
  larger one is a config failure: nothing is sent, the message names the fix,
  and the call fails over to the next candidate.
- `oversize_policy` is `map_reduce` or `fail`, per model. A missing value means
  `map_reduce`, an unknown value is rejected. `code-write` is always `fail`,
  since a partial view of the input would produce wrong files
  ([ADR 0015](0015-code-write-create-only-and-tag-protocol.md)).
- `fail` means "this model refuses, try the next one". Input too large for a
  model is not the model's fault: the refusal sends nothing, records no breaker
  failure and starts no cooldown, and the failover moves to the next candidate.
  The same holds when `map_reduce` cannot fit the input either (the question
  alone leaves no room, or more chunks than the limit would be needed). When no
  candidate takes the input, bulk-read ends with "no delegate model can take
  this input" and Claude reads the file itself, in offset/limit sections.
- The `opencode` transport refuses the same way. `opencode run -f` keeps at most
  2000 lines, 50 KB and 2000 characters per line of an attached file and
  silently drops the rest, so a file over any of these limits, or an input over
  the model's context budget when `context_tokens` is known, is refused before
  opencode is called.
- The size check estimates tokens from bytes and compares them with a fixed
  percentage of `context_tokens`, leaving room for the answer.
- `map_reduce`: the input is split into chunks that fit that budget. Chunks of
  one file overlap by some lines so a finding on a boundary is not lost, a
  single line longer than the budget is split by bytes, and chunks of different
  files are never mixed. Chunks are sent one by one, then the partial answers
  are merged, recursively if the partials are themselves too big, up to a
  bounded depth. Exact figures live as constants in
  `scripts/lib/transport-http.sh`.
- Time limits: `SHUNT_TIMEOUT_SECONDS` limits each request. A chunked call also
  has a total deadline, `SHUNT_TOTAL_TIMEOUT_SECONDS`, defaulting to 3 times the
  per-request limit. Each request is capped by the time left, and no request is
  sent once the deadline passes.
- A failed or timed-out call counts as one failure of that model for the circuit
  breaker ([ADR 0012](0012-circuit-breaker-separate-from-model-selection.md)).
  The whole call is one unit, so the next candidate restarts from scratch.
  `set-context`, `detect-context --write` and `oversize-policy` reset the
  model's breaker state when the fix is saved.

## Consequences

- A large file costs several requests, so it is slower than one request, but its
  answer covers the whole file.
- Chunk overlap can yield duplicate findings, so the merge prompt tells the
  model to combine duplicates.
- The default total deadline never cuts a single request short, but bounds a
  chunked call to roughly three requests' worth of time. Set the variable
  explicitly for larger files.
