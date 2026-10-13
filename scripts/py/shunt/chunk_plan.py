"""Chunk planning for the map_reduce oversize policy of the HTTP transport.

Port of the planner in scripts/lib/transport-http-chunking.sh: line ranges with
overlap, UTF-8 safe byte pieces for a line longer than the budget, the measured
per-file framing overhead, and the cutting of a chunk from its file. Chunk
boundaries and the "part i of n" notes must match the bash version exactly.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from itertools import islice

from .transport_reply import FAILED, OVERSIZE, Abort

CHUNK_OVERLAP_LINES = 20
MIN_CHUNK_BYTES = 200
DEFAULT_MAX_CHUNKS = 100
UTF8_MAX_CONTINUATION = 3
_BLANK = b" \t\r\f\v"  # what awk's [ \t\r\f\v] matches
_SPACE = b" \t\n\v\f\r"  # [[:space:]] in the C locale
NO_OFFSET = -1  # a chunk of whole lines, not a piece of one long line


def to_bytes(text: str) -> bytes:
    return text.encode("utf-8", "surrogateescape")


@dataclass(frozen=True)
class Chunk:
    file: str
    start: int
    end: int
    offset: int  # byte offset in the line `start` for a piece of a long line, else NO_OFFSET
    length: int
    part: int
    total: int

    @property
    def note(self) -> str:
        """`part i of n of <file>, lines a-b` (or the byte range for a split line)."""
        if self.offset >= 0:
            where = f"line {self.start}, bytes {self.offset + 1}-{self.offset + self.length}"
        else:
            where = f"lines {self.start}-{self.end}"
        return f"part {self.part} of {self.total} of {self.file}, {where}"

    @property
    def label(self) -> str:
        """The note without the `part i of n of ` prefix."""
        return self.note[len(f"part {self.part} of {self.total} of "):]


def chunk_question(question: str, note: str) -> str:
    return f"{question}\n\n(This is {note}. Answer for this part only.)"


def chunk_prompt(question: str, label: str, content: bytes) -> bytes:
    """The question, then the chunk in a block labelled with the original file's name."""
    return (to_bytes(question) + b"\n\n--- file: " + to_bytes(label) + b" ---\n" + content
            + b"\n--- end of file ---\n")


def read_lines(path: str, first: int, last: int) -> bytes:
    """Lines first..last (1-based) byte for byte."""
    with open(path, "rb") as handle:
        return b"".join(islice(handle, first - 1, last))


def line_ranges(path: str, budget: int, max_ranges: int) -> Iterator[tuple[int, int, str]]:
    """(first, last, kind) per chunk of whole lines, kind L, or a single line longer than
    the budget as kind B. Consecutive L chunks share up to CHUNK_OVERLAP_LINES lines, and
    at most a quarter of the budget. Streams, and stops once more than max_ranges are out
    because the plan is refused then anyway."""
    lens: dict[int, int] = {}
    start, end, total, low, printed = 1, 0, 0, 1, 0
    with open(path, "rb") as handle:
        for i, line in enumerate(handle, 1):
            size = len(line) + (0 if line.endswith(b"\n") else 1)
            lens[i] = size
            if size > budget:
                if end >= start:
                    yield start, end, "L"
                    printed += 1
                    if printed > max_ranges:
                        return
                yield i, i, "B"
                printed += 1
                if printed > max_ranges:
                    return
                start, end, total = i + 1, i, 0
                continue
            if end >= start and total + size > budget:
                yield start, end, "L"
                printed += 1
                if printed > max_ranges:
                    return
                new_start = max(end - CHUNK_OVERLAP_LINES + 1, start + 1)
                total = sum(lens[j] for j in range(new_start, end + 1))
                while new_start <= end and (total + size > budget or total > budget / 4):
                    total -= lens[new_start]
                    new_start += 1
                if new_start > end:
                    start, total = i, 0
                else:
                    start = new_start
            elif end < start:
                start, total = i, 0
            end = i
            total += size
            while low < start:
                lens.pop(low, None)
                low += 1
    if end >= start:
        yield start, end, "L"


def utf8_cut(data: bytes, pos: int) -> int:
    """Where to split at or just before byte offset pos: the last of offsets pos-3..pos
    whose byte does not continue a UTF-8 character (10xxxxxx). pos when all four do."""
    first = max(pos - UTF8_MAX_CONTINUATION, 0)
    window = data[first:pos + 1]
    for i in range(len(window) - 1, -1, -1):
        if window[i] & 0xC0 != 0x80:
            return first + i
    return pos


def _cut_before_blank_tail(line: bytes, off: int, end: int, budget: int) -> int:
    """The piece off..end is followed by whitespace only: end it at the start of its last
    non-whitespace character instead, so the last piece carries it along with the
    whitespace, when that piece still fits the budget and the cut stays after off."""
    keep = len(line[off:end].rstrip(_BLANK))
    if keep <= 0:
        return end
    cut = utf8_cut(line, off + keep - 1)
    return cut if cut > off and len(line) - cut <= budget else end


def _long_line_pieces(line: bytes, budget: int) -> Iterator[tuple[int, int]]:
    """(offset, length) pieces of one line longer than the budget, each at most the budget
    and split on a UTF-8 character boundary. When the rest after a piece would be only
    whitespace (typically the line's own newline), the piece ends one character earlier,
    so the last request carries real content."""
    size, off = len(line), 0
    while off < size:
        end = off + budget
        if end >= size:
            end = size
        else:
            cut = utf8_cut(line, end)
            if cut > off:
                end = cut
            if size - end <= budget and not line[end:].strip(_SPACE):
                end = _cut_before_blank_tail(line, off, end, budget)
        yield off, end - off
        off = end


def _read_line(path: str, number: int) -> bytes:
    try:
        return read_lines(path, number, number)
    except OSError:
        sys.stderr.write(f"shunt: cannot read {path} to plan it.\n")
        raise Abort(FAILED) from None


def plan_file(path: str, budget: int, room: int) -> list[tuple[int, int, int, int]]:
    """(start, end, offset, length) per chunk of one file: the whole file when it fits, else
    line ranges with overlap, else byte pieces for a line longer than the budget. Stops
    once it holds more than `room` chunks (the plan is refused then)."""
    if os.stat(path).st_size <= budget:
        with open(path, "rb") as handle:
            data = handle.read()
        lines = data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)
        return [(1, max(lines, 1), NO_OFFSET, 0)]
    plan: list[tuple[int, int, int, int]] = []
    for first, last, kind in line_ranges(path, budget, room):
        if kind == "B":
            for off, length in _long_line_pieces(_read_line(path, first), budget):
                plan.append((first, first, off, length))
                if len(plan) > room:
                    break
        else:
            plan.append((first, last, NO_OFFSET, 0))
        if len(plan) > room:
            break
    return plan


def overhead(question: str, label: str, size: str, system_len: int) -> int:
    """Bytes a chunk request of a file named `label` and `size` bytes adds around its content:
    the role prompt plus the chunk prompt around empty content. The note gets the longest
    form a chunk of that file can have, every number with as many digits as the size."""
    nines = "9" * (len(size) or 1)
    note = f"part {nines} of {nines} of {label}, line {nines}, bytes {nines}-{nines}"
    return system_len + len(chunk_prompt(chunk_question(question, note), label, b""))


def plan_all(question: str, files: list[str], *, model_id: str, system_len: int, budget_bytes: int,
             max_chunks: int) -> list[Chunk]:
    """The chunks of every file, in request order. Refuses with OVERSIZE when the role prompt
    and question leave too little room for file content, or the input needs more than
    max_chunks chunks."""
    raw: list[list[tuple[int, int, int, int]]] = []
    count = 0
    # The empty name checks the question alone, which also covers a call without files.
    for path in ["", *files]:
        size = str(os.stat(path).st_size) if path else ""
        room = budget_bytes - overhead(question, path, size, system_len)
        if room < MIN_CHUNK_BYTES:
            sys.stderr.write(f"shunt: model {model_id}: the role prompt and the question leave no room for "
                             "file content in the context budget (no request sent).\n")
            raise Abort(OVERSIZE)
        if path:
            pieces = plan_file(path, room, max_chunks - count)
            raw.append(pieces)
            count += len(pieces)
        if count > max_chunks:
            break
    if count > max_chunks:
        sys.stderr.write(f"shunt: model {model_id}: the input needs more chunks than the limit of "
                         f"{max_chunks} (no request sent).\n")
        raise Abort(OVERSIZE)
    return [Chunk(path, *piece, part, len(pieces))
            for path, pieces in zip(files, raw)
            for part, piece in enumerate(pieces, 1)]


def write_chunk(chunk: Chunk) -> bytes:
    """The bytes of the chunk, cut from its file again. A source that cannot be read, or
    that gives other than the planned byte length, fails the call."""
    path = chunk.file
    if not (os.path.isfile(path) and os.access(path, os.R_OK)):
        sys.stderr.write(f"shunt: cannot read {path} to cut a chunk from it.\n")
        raise Abort(FAILED)
    try:
        if chunk.offset < 0:
            return read_lines(path, chunk.start, chunk.end)
        piece = read_lines(path, chunk.start, chunk.start)[chunk.offset:chunk.offset + chunk.length]
    except OSError:
        sys.stderr.write(f"shunt: cannot read {path} to cut a chunk from it.\n")
        raise Abort(FAILED) from None
    if len(piece) != chunk.length:
        sys.stderr.write(f"shunt: reading {path} gave {len(piece)} bytes, expected {chunk.length} bytes "
                         "(changed or unreadable after planning).\n")
        raise Abort(FAILED)
    return piece
