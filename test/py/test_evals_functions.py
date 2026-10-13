"""Static guard: the eval scripts must not call a shunt_* shell function that no longer exists.

The Python port removed shunt_preflight from scripts/lib while four eval scripts kept
calling it. This check reads the sources only, no network and no providers.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFINITION = re.compile(r"^\s*(?:function\s+)?(shunt_[a-z0-9_]+)\s*\(\)", re.MULTILINE)
# A call: the name at a command position (line start, after a separator or keyword), so that
# variables such as `local shunt_ms` or `shunt_ms=1` and path fragments do not match.
CALL = re.compile(
    r"(?:^|[;&|!]|(?<!\$)\{|\$\(|\b(?:if|then|do|else|elif|while|until))\s*(shunt_[a-z0-9_]+)(?![\w.=-])"
)


def _defined(files):
    return {name for path in files for name in DEFINITION.findall(path.read_text())}


def _called(path):
    names = set()
    for line in path.read_text().splitlines():
        if line.lstrip().startswith("#"):
            continue
        names.update(CALL.findall(line))
    return names


def test_eval_scripts_only_call_defined_shunt_functions():
    lib = sorted((ROOT / "scripts" / "lib").glob("*.sh"))
    evals = sorted((ROOT / "evals").glob("*.sh"))
    assert lib and evals
    known = _defined(lib)
    missing = {
        str(path.relative_to(ROOT)): sorted(_called(path) - known - _defined([path]))
        for path in evals
    }
    missing = {path: names for path, names in missing.items() if names}
    assert not missing, f"eval scripts call undefined shunt_* functions: {missing}"


def test_check_flags_a_removed_function(tmp_path):
    script = tmp_path / "x.sh"
    script.write_text("shunt_preflight\n# shunt_commented\nbin=scripts/shunt_x\nshunt_report_error 'm'\n")
    assert _called(script) == {"shunt_preflight", "shunt_report_error"}
