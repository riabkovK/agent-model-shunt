"""Arguments of code-write: parsing, the refusals that need no file, and the prompt.

Port of cw_parse_args, cw_spec_has_unsafe_chars, the first half of cw_validate_args and
cw_build_prompt / cw_prepare_prompt of scripts/code-write. Every refusal is a `cw_io.Stop`
raised before any model call.
"""

from __future__ import annotations

import os
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from . import cw_text
from .cw_io import clean, fail

MAX_SPEC_CHARS = 32768
MAX_PROMPT_BYTES = 100000
KINDS = ("test", "generic")
TEST_RULES_FILE = str(Path(__file__).resolve().parents[2]) + "/../prompts/test-rules.md"
_VALUE_FLAGS = ("--kind", "--spec")
_FILE_FLAGS = ("--reference", "--source", "--rules", "--target")
_SPACE = " \t\n\v\f\r"
_ALLOWED_IN_SPEC = (b"\n", b"\t", b"\xe2\x80\x8c", b"\xe2\x80\x8d", b"\xef\xb8\x8f")  # LF, tab, ZWNJ, ZWJ, VS16


@dataclass
class Args:
    kind: str = ""
    spec: str = ""
    targets: list[str] = field(default_factory=list)
    references: list[str] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)
    rules: list[str] = field(default_factory=list)
    allow_outside: bool = False
    given: list[str] = field(default_factory=list)

    @property
    def inputs(self) -> list[str]:
        return [*self.references, *self.sources, *self.rules]


def parse_args(argv: Sequence[str]) -> Args:
    """The file flags take every following value up to the next flag and may repeat. --kind and
    --spec take exactly the next word, whatever it looks like, and may be given once."""
    args = Args()
    rest = list(argv)
    mode = ""
    while rest:
        word = rest.pop(0)
        if word in _VALUE_FLAGS:
            if not rest:
                raise fail(f"{word} requires a value.")
            if word in args.given:
                raise fail(f"{word} given more than once.")
            args.given.append(word)
            setattr(args, word[2:], rest.pop(0))
            mode = ""
        elif word in _FILE_FLAGS:
            mode = word[2:]
            args.given.append(word)
        elif word == "--allow-outside":
            args.allow_outside = True
            mode = ""
        elif word.startswith("--"):
            raise fail(f"unknown argument: {clean(word)}")
        elif mode:
            getattr(args, {"reference": "references", "source": "sources", "rules": "rules",
                           "target": "targets"}[mode]).append(word)
        else:
            raise fail(f"unexpected argument: {clean(word)}")
    return args


def spec_has_unsafe_chars(spec: str) -> bool:
    """A control other than tab and newline, DEL or an invisible character. ZWNJ, ZWJ and VS16 are
    dropped first (emoji sequences and Indic text pass), as they are in generated code."""
    raw = os.fsencode(spec)
    for allowed in _ALLOWED_IN_SPEC:
        raw = raw.replace(allowed, b"")
    return cw_text.has_unsafe_chars(raw)


def check_shape(args: Args) -> None:
    """Every refusal that needs neither a file nor the project root."""
    if args.kind not in KINDS:
        if not args.kind:
            raise fail("--kind is required (test or generic).")
        raise fail(f"--kind must be test or generic, got: {clean(args.kind)}")
    if not args.spec.strip(_SPACE):
        raise fail("--spec is required (what to generate).")
    if len(args.spec) > MAX_SPEC_CHARS:
        raise fail(f"--spec is too long ({len(args.spec)} characters, the cap is {MAX_SPEC_CHARS}). "
                   "Put long instructions in a file and pass it with --rules.")
    # After the length cap on purpose: the invisible-character strip is quadratic on nested
    # sequences, so it must only see a bounded spec.
    if spec_has_unsafe_chars(args.spec):
        raise fail("--spec contains a control character or an invisible Unicode character "
                   "(only tab and newline are allowed as controls). Remove it and try again.")
    if not args.references:
        raise fail("--reference requires at least one file.")
    if "--source" in args.given and not args.sources:
        raise fail("--source requires at least one file.")
    if "--rules" in args.given and not args.rules:
        raise fail("--rules requires at least one file.")
    if args.kind == "test" and not args.sources:
        raise fail("--kind test requires --source (the code under test).")
    if not args.targets:
        raise fail("--target is required (the new file to create).")
    if len(args.targets) != 1:
        raise fail(f"exactly one --target is allowed, got {len(args.targets)}. Make one call per file.")


def _section(heading: str, paths: Sequence[str]) -> list[str]:
    return ["", heading, *(f"- {path}" for path in paths)]


def build_prompt(args: Args, test_rules: str) -> str:
    """The message sent with the attached files. The built-in test rules go in for --kind test only
    and cannot be switched off. Trailing newlines are dropped, as a command substitution did."""
    lines = ["Generate one new file, following your instructions for the reply format.", "",
             f"File kind: {args.kind}",
             f"Path of the new file (it does not exist yet): {clean(args.targets[0])}", "",
             "Instructions:", args.spec]
    lines += _section("Reference files (match their style, structure and conventions, do not copy "
                      "their content):", args.references)
    if args.sources:
        lines += _section("Source files (the code the new file is about, the only source of truth for "
                          "symbols and behavior):", args.sources)
    if args.rules:
        lines += _section("Rules files (project conventions to follow):", args.rules)
    lines += ["", "Use only symbols that appear in the attached files. If you need one that is missing, "
              "leave that part out and say so in the notes."]
    text = "\n".join(lines) + "\n"
    if args.kind == "test":
        text += "\n" + test_rules
    return text.rstrip("\n")


def read_test_rules() -> str:
    try:
        with open(TEST_RULES_FILE, "rb") as handle:
            return os.fsdecode(handle.read().replace(b"\0", b""))
    except OSError:
        raise fail(f"the built-in test rules are missing at {TEST_RULES_FILE} "
                   "(incomplete plugin install).") from None


def prepare_prompt(args: Args) -> tuple[str, list[str]]:
    """The prompt and the attachment list (each file once, in order), or a refusal for a prompt that is too big."""
    prompt = build_prompt(args, read_test_rules() if args.kind == "test" else "")
    size = len(os.fsencode(prompt))
    if size > MAX_PROMPT_BYTES:
        raise fail(f"the prompt is too large ({size} bytes, the cap is {MAX_PROMPT_BYTES}). "
                   "Shorten --spec or use fewer files.")
    attachments: list[str] = []
    for path in args.inputs:
        if path not in attachments:
            attachments.append(path)
    return prompt, attachments
