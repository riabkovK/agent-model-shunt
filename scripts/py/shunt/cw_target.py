"""Where a model-written file may land (port of the target half of codewrite.sh).

A purely lexical pass over the components as given, then a physical walk that
resolves symlinks, then the same rule again on the canonical location. Paths are
bytes throughout, so a name is judged on what is on disk, not on a locale's view
of it. Nothing here touches the disk beyond looking.

Residual risk, accepted: TOCTOU. Something running in parallel that swaps a
directory for a symlink after the last check can still redirect a later write.
"""

import fnmatch
import os
from dataclasses import dataclass, field

from .cw_text import has_unsafe_chars

MAX_TARGET_BYTES = 4096  # PATH_MAX, a longer target is refused before anything is created
_TRIM = b". "  # Windows treats '.git.' and '.git ' as '.git'
_DENIED_NAMES = frozenset((
    b"claude.md", b"claude.local.md", b"agents.md", b"gemini.md", b"jenkinsfile", b"opencode.json",
    b"makefile", b"gnumakefile", b"justfile", b"rakefile", b"vagrantfile", b"conftest.py"))
_DENIED_ROOT_NAMES = frozenset((
    b".git", b".claude", b".github", b".config", b".local", b".ssh", b".gnupg", b".aws", b".kube"))
_SENSITIVE_GLOBS = tuple(pattern.encode() for pattern in (
    ".env*", "*.env", ".ssh", ".aws", ".azure", ".gnupg", ".kube", ".netrc", ".npmrc", ".pypirc",
    ".git-credentials", ".docker", ".git", ".claude", ".mcp.json", ".htpasswd", ".pgpass",
    ".credentials.json", ".*history", ".vault-token", ".password-store", ".dockercfg", ".s3cfg", ".boto",
    "application_default_credentials.json", "*.tfstate", "*.tfstate.*", "*.tfvars", "*.tfvars.json", "*.kdbx",
    "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*", "ssh_host_*_key", "*.pem", "*.key", "*.p12", "*.pfx",
    "*.keystore", "*.jks", "credentials", "credentials.*", "*.credentials", "secrets.json", "secrets.yml",
    "secrets.yaml", ".dev.vars*", "serviceaccountkey.json", "*-credentials.json", "client_secret_*.json",
    "firebase-adminsdk-*.json", "wrangler.toml", "local.settings.json", ".yarnrc", ".yarnrc.yml", ".gitconfig",
    ".my.cnf", "_netrc", ".authinfo*", ".terraformrc", ".claude.json", "*.gpg", "*.ppk", "*.p8", "*.asc", "*.ovpn"))
_SENSITIVE_PAIRS = frozenset(pair.encode() for pair in (
    ".config/gh", ".config/gcloud", ".config/opencode", ".config/agent-model-shunt", ".config/rclone",
    ".config/doctl", ".config/heroku", ".config/op", ".config/sops", ".composer/auth.json", ".m2/settings.xml"))
_SENSITIVE_TRIPLES = frozenset((b".local/share/opencode",))
_DENIED_HINT = (
    "(dotted names such as .git, .github, .claude, .env* and .mcp.json, and CLAUDE.md, AGENTS.md, GEMINI.md, "
    "opencode.json, Jenkinsfile and Makefile are off limits). A target like this must be written by Claude "
    "itself with the Write tool, which asks for permission, not by code-write")
_UNSAFE_ROOT = "the project root path contains control characters or invisible Unicode characters"
_UNSAFE_TARGET = "the target contains control characters or invisible Unicode characters"


class Refusal(Exception):
    """A path that must not be written. The text is the reason shown to the user."""


@dataclass(frozen=True)
class Resolved:
    root: bytes
    ancestor: bytes
    resolved: bytes
    missing: tuple[bytes, ...] = field(default_factory=tuple)


def _show(raw: bytes) -> str:
    return os.fsdecode(raw)


def canon_dir(path: bytes) -> bytes | None:
    """The physical absolute path of an existing, enterable directory, else None (cd -P; pwd -P)."""
    try:
        real = os.path.realpath(path, strict=True)
    except (OSError, ValueError):
        return None
    if not os.path.isdir(real) or not os.access(real, os.X_OK):
        return None
    return real


def _trim(part: bytes) -> bytes:
    return part.rstrip(_TRIM)


def sensitive_component(path: bytes) -> bytes | None:
    """The first component (or run of components) naming a credential, key or state store."""
    prev = prev2 = b""
    for part in path.lower().split(b"/"):
        trimmed = _trim(part)
        if not trimmed:
            continue
        if any(fnmatch.fnmatchcase(trimmed, glob) for glob in _SENSITIVE_GLOBS):
            return trimmed
        if prev + b"/" + trimmed in _SENSITIVE_PAIRS:
            return prev + b"/" + trimmed
        if prev2 + b"/" + prev + b"/" + trimmed in _SENSITIVE_TRIPLES:
            return prev2 + b"/" + prev + b"/" + trimmed
        prev2, prev = prev, trimmed
    return None


def find_denied(path: bytes) -> bytes | None:
    """The first component of a target that code-write must not write to: dotted, or a steering file name."""
    for part in path.lower().split(b"/"):
        if part in (b"", b".", b".."):
            continue
        trimmed = _trim(part)
        if not trimmed or trimmed.startswith(b"."):
            return trimmed or part
        if trimmed in _DENIED_NAMES:
            return trimmed
    return None


def find_denied_root(path: bytes) -> bytes | None:
    """The short list for a root that fell back to the cwd (no dot rule: ~/.cache is fine)."""
    for part in path.lower().split(b"/"):
        trimmed = _trim(part)
        if trimmed in _DENIED_ROOT_NAMES:
            return trimmed
    return None


def _denied_reason(path: bytes) -> str | None:
    denied = find_denied(path)
    if denied is None:
        return None
    return f"the path component '{_show(denied)}' is not allowed {_DENIED_HINT}"


def split_path(path: bytes) -> list[bytes]:
    """Components BEFORE any normalization: '.', '..' and empty ones are refused as such."""
    parts = path.split(b"/")
    for part in parts:
        if part == b"":
            raise Refusal("the path has an empty component")
        if part == b".":
            raise Refusal("the path has a '.' component")
        if part == b"..":
            raise Refusal("the path has a '..' component")
    return parts


def check_placement(root: bytes, canon: bytes, tail: bytes) -> None:
    """canon must be root or below it (whole components) and no root-relative component may be denied."""
    if canon != root and not canon.startswith(root + b"/"):
        raise Refusal("it resolves outside the project root")
    rel = canon[len(root):]
    rel = rel[1:] if rel.startswith(b"/") else rel
    if tail:
        rel = rel + b"/" + tail if rel else tail
    reason = _denied_reason(rel)
    if reason:
        raise Refusal(reason)


def _prepare(root_in: bytes, target: bytes) -> tuple[bytes, bytes, list[bytes]]:
    """The lexical half: the canonical root, the walk's base directory and the components."""
    if not root_in.startswith(b"/"):
        raise Refusal("the project root must be an absolute path")
    if has_unsafe_chars(root_in):
        raise Refusal(_UNSAFE_ROOT)
    root = canon_dir(root_in)
    if root is None:
        raise Refusal(f"the project root '{_show(root_in)}' is not a directory")
    if root == b"/":
        raise Refusal("the project root is the filesystem root")
    if has_unsafe_chars(root):
        raise Refusal(_UNSAFE_ROOT)
    if not target:
        raise Refusal("the target is empty")
    if len(target) > MAX_TARGET_BYTES:
        raise Refusal(f"the target is longer than {MAX_TARGET_BYTES} characters")
    if has_unsafe_chars(target):
        raise Refusal(_UNSAFE_TARGET)
    if target.endswith(b"/"):
        raise Refusal("the target ends with a slash")
    base, path = root, target
    if target.startswith(b"/"):
        # Validate the whole absolute path first. Under the canonical root, walk
        # from the root with the part below it. Any other absolute spelling
        # (an alias reaching the root through a symlink) walks from / and gets
        # the lexical rule on its full path: stricter than needed, never lax.
        split_path(target[1:])
        if target.startswith(root + b"/"):
            path = target[len(root) + 1:]
        else:
            base, path = b"/", target[1:]
    # Lexical pass over the components as given, on top of the canonical pass
    # later: a symlink named .claude that points elsewhere is still refused.
    reason = _denied_reason(path)
    if reason:
        raise Refusal(reason)
    return root, base, split_path(path)


def resolve(root_in: bytes, target: bytes) -> Resolved:
    """Pure check. Raises Refusal, else describes the new file's place."""
    root, base, parts = _prepare(root_in, target)
    cur, index = base, 0
    while index < len(parts):
        nxt = (cur[:-1] if cur.endswith(b"/") else cur) + b"/" + parts[index]
        if not os.path.lexists(nxt):  # a dangling symlink counts as existing
            break
        cur, index = nxt, index + 1
    if index == len(parts):
        # Outside the root the answer matches a missing path, so it does not tell whether a file exists.
        raise Refusal("it is not a new path inside the project root" if base == b"/"
                      else "it already exists (code-write only creates new files)")
    canon = canon_dir(cur)
    if canon is None:
        raise Refusal(f"'{_show(cur)}' exists but is not a directory that can be entered "
                      "(a file, or a dangling or broken symlink)")
    if has_unsafe_chars(canon):
        raise Refusal("the resolved directory contains control characters or invisible Unicode characters")
    missing = tuple(parts[index:])
    joined = b"/".join(missing)
    check_placement(root, canon, joined)
    return Resolved(root, canon, (canon[:-1] if canon.endswith(b"/") else canon) + b"/" + joined, missing)


def root_denied_hit(canon: bytes) -> bytes | None:
    """For a cwd fallback root: the path component that makes it off limits, if any."""
    below = canon[1:]
    return find_denied_root(below) or sensitive_component(below)
