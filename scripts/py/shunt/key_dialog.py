"""shunt-key-dialog: store a provider's API key from a hidden GUI password dialog.

The key never touches the chat, a command line, a log or Claude's tool output. The
dialog opens on the user's desktop. Its output goes straight into `shunt-models key
set` on a pipe, so the key is never an argument of any process.

Usage: shunt-key-dialog <provider>

Environment:
  SHUNT_KEY_DIALOG          zenity | kdialog | osascript | none (default: auto)
  SHUNT_KEY_DIALOG_TIMEOUT  seconds before the dialog gives up (default 120)

Exit codes:
  0 key stored (prints `key status` output only)
  1 refused: unknown provider, or key type env/none (nothing to enter)
  2 usage error
  3 no key entered (cancelled or empty), nothing stored
  4 dialog timed out, nothing stored
  5 no dialog available, prints the manual `!` fallback line
  6 storing the key failed
"""

import os
import re
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

from . import env, models_cli, probe, providers
from .providers import ProviderError

COMMAND = "shunt-key-dialog"
EXIT_REFUSED, EXIT_USAGE, EXIT_NO_KEY, EXIT_TIMEOUT, EXIT_NO_DIALOG, EXIT_STORE = 1, 2, 3, 4, 5, 6
DEFAULT_DIALOG_TIMEOUT = 120
TOOL_TIMED_OUT = 124  # what timeout(1) returns, and what run_dialog reports for any dialog that gave up
ZENITY_TIMED_OUT = 5
# What the AppleScript prints when the dialog gave up. A cancelled dialog is an
# AppleScript error (-128, exit 1), so the two cases need different signals.
OSASCRIPT_GAVE_UP = "__SHUNT_DIALOG_GAVE_UP__"
_TIMEOUT_RE = re.compile(r"[1-9][0-9]*")
_SPACE = " \t\n\v\f\r"  # the bash [[:space:]] set
_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_APPLESCRIPT = (
    "on run argv",
    "set r to display dialog (item 1 of argv) default answer \"\" with hidden answer "
    "with title (item 2 of argv) giving up after (item 3 of argv as integer)",
    f"if gave up of r then return \"{OSASCRIPT_GAVE_UP}\"",
    "return text returned of r",
    "end run",
)


def _say(text: str) -> None:
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def _warn(text: str) -> None:
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def _timeout_seconds(environ: Mapping[str, str]) -> int:
    text = environ.get("SHUNT_KEY_DIALOG_TIMEOUT", str(DEFAULT_DIALOG_TIMEOUT))
    return int(text) if _TIMEOUT_RE.fullmatch(text) else DEFAULT_DIALOG_TIMEOUT


def _is_darwin() -> bool:
    return os.uname().sysname == "Darwin"


def _dialog_usable(tool: str) -> bool:
    """kdialog has no timeout of its own, so it is only used where `timeout` exists."""
    if shutil.which(tool) is None:
        return False
    return tool != "kdialog" or shutil.which("timeout") is not None


def pick_dialog(environ: Mapping[str, str]) -> str:
    """The dialog tool to use, or "none"."""
    choice = environ.get("SHUNT_KEY_DIALOG") or "auto"
    if choice in ("zenity", "kdialog", "osascript"):
        return choice if _dialog_usable(choice) else "none"
    if choice == "none":
        return "none"
    # Over SSH a GUI dialog would open on the remote desktop, not where the user is.
    if environ.get("SSH_CONNECTION") or environ.get("SSH_TTY"):
        _warn("shunt: no key window opened because this is an SSH session. "
              "Set SHUNT_KEY_DIALOG=zenity (or kdialog, osascript) to force one.")
        return "none"
    if _is_darwin():
        return "osascript" if shutil.which("osascript") else "none"
    if environ.get("DISPLAY") or environ.get("WAYLAND_DISPLAY"):
        for tool in ("zenity", "kdialog"):
            if _dialog_usable(tool):
                return tool
    return "none"


def _dialog_argv(dialog: str, provider: str, timeout_s: int) -> list[str]:
    prompt = f"Enter the API key for provider {provider}"
    title = f"Model Shunt: {provider}"
    if dialog == "zenity":
        return ["zenity", "--password", f"--title=Model Shunt: {provider} API key", f"--timeout={timeout_s}"]
    if dialog == "kdialog":
        return ["timeout", str(timeout_s), "kdialog", "--title", title, "--password", prompt]
    script = [part for line in _APPLESCRIPT for part in ("-e", line)]
    return ["osascript", *script, "--", prompt, title, str(timeout_s)]


def run_dialog(dialog: str, provider: str, timeout_s: int) -> tuple[int, bytes]:
    """The exit code (0 text entered, 124 timed out, else cancelled or failed) and the typed bytes.

    The text is never passed as an argument. Like the bash command substitution, the
    output loses its trailing newlines and any NUL byte.
    """
    try:
        done = subprocess.run(_dialog_argv(dialog, provider, timeout_s), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return 1, b""
    code, out = done.returncode, done.stdout.replace(b"\0", b"").rstrip(b"\n")
    if dialog == "zenity" and code == ZENITY_TIMED_OUT:
        code = TOOL_TIMED_OUT
    if dialog == "osascript" and out == OSASCRIPT_GAVE_UP.encode():
        return TOOL_TIMED_OUT, b""
    return code, out


def clean_key(raw: bytes) -> str:
    """Trim whitespace and one pair of wrapping quotes, as pasted keys often carry them."""
    key = raw.decode("utf-8", "surrogateescape").strip(_SPACE)
    if len(key) >= 2 and key[0] == key[-1] and key[0] in "\"'":
        key = key[1:-1]
    return key


def _run_models(args: Sequence[str], **kwargs) -> int:
    """Run shunt-models. BASH_ENV and ENV are dropped: a startup file that turns on xtrace would print the key."""
    models_bin = Path(os.path.abspath(__file__)).parents[2] / models_cli.COMMAND
    child_env = {name: value for name, value in os.environ.items() if name not in ("BASH_ENV", "ENV")}
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        return subprocess.run([str(models_bin), *args], env=child_env, check=False, **kwargs).returncode
    except OSError:
        return 1


def _store(provider: str, key: str) -> int:
    """Pipe the key to `shunt-models key set`. Its stderr never holds the key, so it passes through."""
    data = key.encode("utf-8", "surrogateescape") + b"\n"
    return _run_models(["key", "set", provider], input=data, stdout=subprocess.DEVNULL)


def _refuse_provider(provider: str, path: str) -> int | None:
    """An exit status when the provider cannot take a typed key, else None."""
    if not _NAME_RE.fullmatch(provider):
        lines, _code = probe.ask(os.environ, "provider-name-refusal", provider)
        _warn("\n".join(lines))
        return EXIT_REFUSED
    if not os.path.isfile(path) or probe.ask(os.environ, "provider-exists", provider)[1] != 0:
        _warn(f"shunt: provider '{provider}' is not in {path}. Create it first with: {models_cli._hint_cmd()} provider set")
        return EXIT_REFUSED
    return None


def _refuse_key_type(provider: str, key_type: str) -> int | None:
    if key_type == "env":
        _warn(f"shunt: provider '{provider}' uses an env key. Nothing to enter: export the variable named in its key.ref in your shell.")
        return EXIT_REFUSED
    if key_type == "none":
        _warn(f"shunt: provider '{provider}' has key type none. There is no key to enter.")
        return EXIT_REFUSED
    return None


def _no_dialog(provider: str) -> int:
    _say("shunt: no password dialog available (need zenity or kdialog with a display, or osascript on macOS).")
    _say("Run this yourself, it reads the key from a hidden prompt:")
    _say(f"! {models_cli._hint_cmd()} key set {providers._bash_quote(provider)}")
    return EXIT_NO_DIALOG


def _typed_key(dialog: str, provider: str, timeout_s: int) -> tuple[str, int]:
    """The cleaned key and 0, or an empty key and the exit status after the message."""
    code, raw = run_dialog(dialog, provider, timeout_s)
    if code == TOOL_TIMED_OUT:
        _warn(f"shunt: the dialog timed out after {timeout_s}s. No key entered, nothing stored.")
        return "", EXIT_TIMEOUT
    key = clean_key(raw) if code == 0 else ""
    if not key:
        _warn("shunt: no key entered, nothing stored.")
        return "", EXIT_NO_KEY
    if "\n" in key:  # storing only the first line would keep a wrong key silently
        _warn("shunt: the pasted key contains a line break, nothing stored. Paste the key alone.")
        return "", EXIT_NO_KEY
    return key, 0


def main(argv: Sequence[str]) -> int:
    if len(argv) != 1 or not argv[0]:
        _warn("usage: shunt-key-dialog <provider>")
        return EXIT_USAGE
    provider = argv[0]
    timeout_s = _timeout_seconds(os.environ)
    path = env.providers_file_text(os.environ)
    refused = _refuse_provider(provider, path)
    if refused is not None:
        return refused
    try:
        key_type = providers.field(path, provider, "key-type")
    except ProviderError as exc:
        _warn(f"shunt: {exc}")
        return exc.code
    refused = _refuse_key_type(provider, key_type)
    if refused is not None:
        return refused
    dialog = pick_dialog(os.environ)
    if dialog == "none":
        return _no_dialog(provider)
    if _is_darwin() and key_type == "keyring":
        _say("shunt: note: on macOS the keychain tool receives the key as a command argument, "
             "so it is briefly visible to local processes. An env key avoids that.")
    key, status = _typed_key(dialog, provider, timeout_s)
    if status:
        return status
    stored = _store(provider, key)
    del key
    if stored != 0:
        _warn(f"shunt: storing the key for '{provider}' failed. Check: {models_cli._hint_cmd()} key status {providers._bash_quote(provider)}")
        return EXIT_STORE
    if key_type == "plaintext":
        _say(providers.plaintext_warning(path))
    return _run_models(["key", "status", provider])
