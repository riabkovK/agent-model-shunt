"""Runner for the Python core. Invoked as `python3 -I -B shunt_main.py <cmd>`.

-I drops the script directory from sys.path, so it is added back by hand.
The version gate uses only syntax that parses on old interpreters.
"""

import os
import sys

MIN_PYTHON = (3, 11)
BROKEN_PIPE_EXIT = 141


def check_python(version_info=None):
    """Return an error message if the interpreter is too old, else None."""
    current = tuple(version_info if version_info is not None else sys.version_info)
    if current[:2] >= MIN_PYTHON:
        return None
    return "shunt: Python %d.%d or newer is required, found %d.%d" % (
        MIN_PYTHON[0], MIN_PYTHON[1], current[0], current[1])


def run():
    error = check_python()
    if error:
        sys.stderr.write(error + "\n")
        return 2
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from shunt.cli import main
    # Bytes in, bytes out: ids and paths are not ASCII, and the locale must not matter.
    sys.stdout.reconfigure(encoding="utf-8", errors="surrogateescape")
    sys.stderr.reconfigure(encoding="utf-8", errors="surrogateescape")
    try:
        code = main(sys.argv[1:])
        sys.stdout.flush()
        return code
    except BrokenPipeError:
        # The reader went away (`| head`). Exit quietly like a process killed by
        # SIGPIPE would: 141 = 128 + 13. Point stdout at devnull so the interpreter's
        # final flush does not print "Exception ignored ... BrokenPipeError".
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return BROKEN_PIPE_EXIT


if __name__ == "__main__":
    sys.exit(run())
