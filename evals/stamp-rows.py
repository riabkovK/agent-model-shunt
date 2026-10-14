#!/usr/bin/env python3
"""Adds claude_model and delegate_model to every row of a results JSONL file,
so the file alone says what it measured.

Usage: stamp-rows.py <file> <claude-model> <delegate-model> [<delegate-kinds>]

An empty delegate model is stored as null. <delegate-kinds> is a space
separated list of the kinds that call the delegate: a row whose `kind` is not
a string equal to one of them gets delegate_model null. Rows without a `kind`
(fidelity: every row asks the delegate) always get it. With no kinds listed
every row gets it. A line that is not a JSON object, or a file that is not
UTF-8, leaves the file as it was, with a warning and status 1.
"""
import json
import os
import sys
import tempfile


def stamp(text, claude_model, delegate_model, kinds):
    out = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError("row is not an object")
        kind = row.get("kind")
        calls_delegate = "kind" not in row or not kinds or (isinstance(kind, str) and kind in kinds)
        row["claude_model"] = claude_model
        row["delegate_model"] = delegate_model if delegate_model and calls_delegate else None
        out.append(json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n")
    return "".join(out)


def main(argv):
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    file, claude_model, delegate_model = argv[1:4]
    kinds = argv[4].split() if len(argv) == 5 else []
    target = os.path.realpath(file)
    tmp = None
    try:
        with open(target, encoding="utf-8", newline="") as f:
            text = f.read()
        stamped = stamp(text, claude_model, delegate_model, kinds)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=os.path.basename(target) + ".tmp.")
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(stamped)
        os.chmod(tmp, os.stat(target).st_mode & 0o7777)
        os.replace(tmp, target)
    except (OSError, ValueError) as exc:  # JSONDecodeError and UnicodeDecodeError are ValueErrors
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        print(f"evals: could not add the model fields to {file} ({exc}); its rows stay as they were.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
