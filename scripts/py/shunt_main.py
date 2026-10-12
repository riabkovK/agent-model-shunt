"""Runner for the Python core. Invoked as `python3 -I -B shunt_main.py <cmd>`.

-I drops the script directory from sys.path, so it is added back by hand.
The version gate uses only syntax that parses on old interpreters.
"""

import os
import sys

MIN_PYTHON = (3, 11)


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
    return main(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(run())
