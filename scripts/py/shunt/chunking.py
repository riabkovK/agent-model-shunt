"""map_reduce for an input that is too large for one request, in one process.

Port of the map and reduce steps of scripts/lib/transport-http-chunking.sh: plan
the chunks (chunk_plan), ask each one, merge the partial answers in rounds, and
total the usage of every request. The asking itself is a callable handed in by
transport_http, which owns the registry entry, the key and the deadline.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from . import chunk_plan
from .deadline import Deadline
from .chunk_plan import to_bytes
from .transport_reply import ERROR, Abort

BYTES_PER_TOKEN = 3
CONTEXT_BUDGET_PERCENT = 60
MAX_MERGE_DEPTH = 3
PARTIAL_RESERVE_BYTES = 100
MERGE_INSTRUCTION = (
    "The input was too large to send at once, so it was analysed in parts. Below are the partial "
    "answers to the question above, one per part. Neighbouring parts of one file share "
    f"{chunk_plan.CHUNK_OVERLAP_LINES} lines, so the same finding can appear twice. Combine them "
    "into one final answer to the question, without repeating duplicates."
)
_CONTEXT_RE = re.compile(r"[0-9]{1,12}")

Ask = Callable[[bytes], dict[str, Any]]


def budget_bytes(context_tokens: str) -> int:
    """The request size, in bytes, a model with this context_tokens accepts."""
    if not _CONTEXT_RE.fullmatch(context_tokens):
        return 0
    return int(context_tokens) * CONTEXT_BUDGET_PERCENT // 100 * BYTES_PER_TOKEN


def max_chunks(environ: Mapping[str, str]) -> int:
    raw = environ.get("SHUNT_HTTP_MAX_CHUNKS", "")
    return int(raw) if re.fullmatch(r"[1-9][0-9]{0,8}", raw) else chunk_plan.DEFAULT_MAX_CHUNKS


def _jq_text(text: str) -> str:
    """The text as `$(jq -r .text)` gave it: no NUL, no trailing newlines, lone surrogates as U+FFFD."""
    clean = text.encode("utf-8", "surrogatepass").decode("utf-8", "replace")
    return clean.replace("\0", "").rstrip("\n")


def _whole(value: Any) -> int:
    """A token count is a non-negative whole number, anything else counts as 0."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


class Usage:
    """Usage totals over all requests of one chunked call."""

    def __init__(self) -> None:
        self.has_usage = False
        self.tokens_in = 0
        self.tokens_out = 0
        self.cost: float | None = None

    def add(self, reply: dict[str, Any]) -> None:
        usage = reply.get("usage")
        if isinstance(usage, dict):
            self.has_usage = True
            self.tokens_in += _whole(usage.get("input"))
            self.tokens_out += _whole(usage.get("output"))
        cost = reply.get("cost")
        if isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0:
            self.cost = (self.cost or 0) + cost

    def apply(self, reply: dict[str, Any]) -> dict[str, Any]:
        """The reply with its usage and cost replaced by the totals of the whole call."""
        total = {k: v for k, v in reply.items() if k not in ("usage", "cost")}
        if self.has_usage:
            total["usage"] = {"input": self.tokens_in, "output": self.tokens_out}
        if self.cost is not None:
            total["cost"] = int(self.cost) if float(self.cost).is_integer() else self.cost
        return total


@dataclass
class _Partials:
    texts: list[str]
    labels: list[str]


class _Merger:
    def __init__(self, question: str, model_id: str, limit: int, ask: Callable[[bytes], dict[str, Any]]) -> None:
        self.question = question
        self.model_id = model_id
        self.limit = limit
        self.ask = ask

    def prompt(self, partials: _Partials, first: int, last: int) -> bytes:
        parts = [f"{self.question}\n\n{MERGE_INSTRUCTION}\n"]
        for i in range(first, last):
            parts.append(f"\n--- partial answer {i + 1} of {len(partials.texts)} ({partials.labels[i]}) ---\n"
                         f"{partials.texts[i]}\n")
        return to_bytes("".join(parts))

    def fail(self, why: str) -> Abort:
        sys.stderr.write(f"shunt: model {self.model_id}: the partial answers cannot be merged ({why}), no result.\n")
        return Abort(ERROR)

    def group(self, partials: _Partials, first: int, last: int, out: _Partials) -> None:
        """A group of one partial needs no request and is carried over unchanged."""
        if last - first == 1:
            out.texts.append(partials.texts[first])
            out.labels.append(partials.labels[first])
            return
        reply = self.ask(self.prompt(partials, first, last))
        out.texts.append(_jq_text(reply["text"]))
        out.labels.append(f"merged parts {partials.labels[first]} .. {partials.labels[last - 1]}")

    def round(self, partials: _Partials) -> _Partials:
        """Groups neighbouring partial answers so each group's merge request fits the budget."""
        base = len(self.prompt(_Partials([], []), 0, 0))
        out = _Partials([], [])
        first, running = 0, base
        for i, (text, label) in enumerate(zip(partials.texts, partials.labels)):
            size = len(to_bytes(text + label)) + PARTIAL_RESERVE_BYTES
            if base + size > self.limit:
                raise self.fail("one partial answer alone is too big")
            if i > first and running + size > self.limit:
                self.group(partials, first, i, out)
                first, running = i, base
            running += size
        self.group(partials, first, len(partials.texts), out)
        return out

    def merge(self, partials: _Partials) -> dict[str, Any]:
        """Reduce step: groups first while the partials do not fit in one request, at most
        MAX_MERGE_DEPTH group rounds, then one request for the final answer."""
        depth = 0
        while True:
            prompt = self.prompt(partials, 0, len(partials.texts))
            if len(prompt) <= self.limit:
                return self.ask(prompt)
            if depth >= MAX_MERGE_DEPTH:
                raise self.fail(f"still too big after {MAX_MERGE_DEPTH} rounds of merging, depth cap reached")
            before = len(partials.texts)
            partials = self.round(partials)
            if len(partials.texts) >= before:
                raise self.fail("merging made no progress")
            depth += 1


def map_reduce(question: str, files: Sequence[str], *, model_id: str, system_len: int, context_tokens: str,
               ask: Ask, environ: Mapping[str, str], progress: Deadline) -> dict[str, Any]:
    """Asks each chunk with the question (map), then merges the partial answers into one
    (reduce). Returns the final reply with usage totals over every request. Any failing
    request aborts and no later request is sent. `progress` has chunks_done/chunks_total
    for the deadline message."""
    budget = budget_bytes(context_tokens)
    plan = chunk_plan.plan_all(question, list(files), model_id=model_id, system_len=system_len,
                               budget_bytes=budget, max_chunks=max_chunks(environ))
    if not plan:
        sys.stderr.write(f"shunt: model {model_id}: the input gives no chunks to send (no request sent).\n")
        raise Abort(ERROR)
    usage = Usage()

    def counted(prompt: bytes) -> dict[str, Any]:
        reply = ask(prompt)
        usage.add(reply)
        return reply

    progress.chunks_total, progress.chunks_done = len(plan), 0
    sys.stderr.write(f"shunt: model {model_id}: input is too large for one request, asking in "
                     f"{len(plan)} parts and merging.\n")
    partials = _Partials([], [])
    reply: dict[str, Any] = {}
    for i, chunk in enumerate(plan):
        asked = chunk_plan.chunk_question(question, chunk.note)
        reply = counted(chunk_plan.chunk_prompt(asked, chunk.file, chunk_plan.write_chunk(chunk)))
        progress.chunks_done = i + 1
        if len(plan) > 1:
            partials.texts.append(_jq_text(reply["text"]))
            partials.labels.append(chunk.label)
    if len(plan) > 1:
        limit = budget - system_len
        reply = _Merger(question, model_id, limit, counted).merge(partials)
    return usage.apply(reply)
