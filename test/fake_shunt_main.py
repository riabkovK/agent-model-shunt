"""shunt_main.py for the bats tests of the HTTP transport (see http_fake.bash).

Selected through SHUNT_PY_MAIN, so the production code has no test hooks. Before the
real runner starts it patches, in this process only:
  - the deadline clock, when FAKE_CLOCK names a file holding the time in seconds,
  - the request function, which per request (a) writes the scripted route from the
    FAKE_CURL_* knobs (FAKE_CURL_BODY, FAKE_CURL_CODE, FAKE_CURL_FAIL_AT/_CODE,
    FAKE_CURL_EXIT 28|7|52), (b) appends the time limit it was given to
    FAKE_HTTP_MAXTIMES (the real one, even when FAKE_CURL_EXIT=28 shortens it), and
    (c) moves the fake clock by FAKE_CURL_ADVANCE after the request.
"""

import os
import runpy
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STALL_SECONDS = "5"
SHORT_LIMIT = 0.3


def _count(log: str) -> int:
    path = Path(log)
    return len(path.read_text().splitlines()) if path.exists() else 0


def _sync_route(env) -> None:
    """The route of the next request, from the FAKE_CURL_* knobs (the old fake curl's behaviour)."""
    route = Path(env["FAKE_HTTP_ROUTES"]) / "v1_chat_completions"
    code = env.get("FAKE_CURL_CODE", "200")
    if str(_count(env["FAKE_HTTP_LOG"]) + 1) == env.get("FAKE_CURL_FAIL_AT", ""):
        code = env["FAKE_CURL_FAIL_CODE"]
    route.with_name(route.name + ".code").write_text(code + "\n")
    for suffix in (".delay", ".drop"):
        route.with_name(route.name + suffix).unlink(missing_ok=True)
    mode = env.get("FAKE_CURL_EXIT", "0")
    if mode == "28":
        route.with_name(route.name + ".delay").write_text(STALL_SECONDS + "\n")
    elif mode in ("7", "52"):
        route.with_name(route.name + ".drop").write_text("")
    shutil.copyfile(env["FAKE_CURL_BODY"], route)


def _patch(env) -> None:
    sys.path.insert(0, str(ROOT / "scripts" / "py"))
    from shunt import deadline, httpclient

    clock = env.get("FAKE_CLOCK")
    if clock:
        deadline.TICKS_PER_SECOND = 1
        deadline.now_ticks = lambda: int(Path(clock).read_text())
    real_post = httpclient.post_json

    def post_json(url, payload, *, headers=None, timeout=None, max_bytes=0):
        if env.get("FAKE_HTTP_ROUTES") and env.get("FAKE_CURL_BODY"):
            _sync_route(env)
        with open(env["FAKE_HTTP_MAXTIMES"], "a") as handle:
            handle.write(f"{timeout or 0:g}\n")
        if env.get("FAKE_CURL_EXIT") == "28":
            timeout = SHORT_LIMIT
        try:
            return real_post(url, payload, headers=headers, timeout=timeout, max_bytes=max_bytes)
        finally:
            if clock:
                now = int(Path(clock).read_text())
                Path(clock).write_text(str(now + int(env.get("FAKE_CURL_ADVANCE", "0"))) + "\n")

    httpclient.post_json = post_json


if __name__ == "__main__":
    _patch(os.environ)
    sys.argv[0] = str(ROOT / "scripts" / "py" / "shunt_main.py")
    runpy.run_path(sys.argv[0], run_name="__main__")
