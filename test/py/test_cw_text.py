"""The text gates of code-write (cw_text.py), plus the `codewrite` CLI group."""

import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import cw_text

ZWSP = "​".encode()
RLO = "‮".encode()
TAG_A = "\U000e0041".encode()
SHY = "­".encode()
C1_CSI = "\u009b".encode()


def written(tmp_path, data: bytes):
    path = tmp_path / "f.txt"
    path.write_bytes(data)
    return str(path)


def cli(*args, **kw):
    return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "codewrite", *args],
                          capture_output=True, **kw)


@pytest.mark.parametrize("hidden", [ZWSP, RLO, TAG_A, SHY, C1_CSI, "﻿".encode(), "⠀".encode(),
                                    "️".encode(), " ".encode(), "ㅤ".encode()])
def test_strip_invisible_removes_hidden_characters(hidden):
    assert cw_text.strip_invisible(b"a" + hidden + b"b") == b"ab"


def test_strip_invisible_runs_to_a_fixed_point_for_nested_sequences():
    # Arrange: a zero width space split by a soft hyphen joins up after the first pass
    nested = b"\xe2\x80" + SHY + b"\x8b"
    # Act / Assert
    assert cw_text.strip_invisible(b"x" + nested + b"y") == b"xy"


def test_strip_invisible_keeps_c0_controls_newlines_and_plain_unicode():
    assert cw_text.strip_invisible("a\tb\nc\x1bd é中".encode()) == "a\tb\nc\x1bd é中".encode()


@pytest.mark.parametrize("text,expected", [
    (b"plain/path.py", False), (b"a\nb", True), (b"a\x7fb", True), (b"a\rb", True),
    (b"a" + ZWSP, True), (b"a" + RLO, True), (b"a\xe2\x80\x8cb", True), ("é/ü.py".encode(), False)])
def test_has_unsafe_chars(text, expected):
    assert cw_text.has_unsafe_chars(text) is expected


@pytest.mark.parametrize("value,expected", [
    ("100", 100), ("0007", 7), ("", 5), ("-3", 5), ("1.5", 5), ("1" * 16, 5), ("1" * 15, int("1" * 15)),
    ("٣", 5), ("12 ", 5)])
def test_limit_accepts_only_a_plain_integer_of_at_most_15_digits(value, expected):
    assert cw_text.limit(value, 5) == expected


@pytest.mark.parametrize("data,reason", [
    (b"ok\tline\n\x0c\r\n", ""), ("é中\U0001f600".encode(), ""), (b"", ""),
    (b"a\x00b", "nul-bytes"), (b"a\x01b", "control-characters"), (b"a\x0bb", "control-characters"),
    (b"a\x7fb", "control-characters"), (b"a" + C1_CSI, "control-characters"),
    (b"\xc2\x85", "control-characters"), (b"a\xffb", "invalid-utf8"), (b"\xed\xa0\x80", "invalid-utf8"),
    (b"\xc0\x80", "invalid-utf8"), (b"\xf4\x90\x80\x80", "invalid-utf8"), (b"a\xe2\x80", "invalid-utf8"),
    (b"if x:" + RLO + b" # ", "bidi-controls"), ("⁦".encode(), "bidi-controls"),
    ("⁩".encode(), "bidi-controls"), (ZWSP, "")])
def test_check_text_reason(tmp_path, data, reason):
    assert cw_text.check_text(written(tmp_path, data)) == reason


def test_check_text_treats_an_unreadable_file_as_a_refusal(tmp_path):
    assert cw_text.check_text(str(tmp_path / "missing")) == "invalid-utf8"


@pytest.mark.parametrize("data,reason", [
    (b"a\r\nb\r\n", ""), (b"a\nb", ""), (b"a\rEVIL\n", "control-characters"), (b"a\r", "control-characters"),
    (b"a\r\r\n", "control-characters"), (b"a\x0cb", "control-characters"), (b"\r\n\r", "control-characters")])
def test_check_code_controls_refuses_lone_cr_and_form_feed(tmp_path, data, reason):
    assert cw_text.check_code_controls(written(tmp_path, data)) == reason


@pytest.mark.parametrize("data,reason", [
    (b"x = 1\n", ""), ("ok ‍‌ ️".encode(), ""),
    (b"x" + ZWSP, "invisible-characters"), (b"x" + TAG_A, "invisible-characters"),
    (b"x\xe2\x80\x8d" + SHY, "invisible-characters"), ("﻿x".encode(), "invisible-characters"),
    (" ".encode(), "invisible-characters")])
def test_check_invisible_allows_only_joiners_and_emoji_selector(tmp_path, data, reason):
    assert cw_text.check_invisible(written(tmp_path, data)) == reason


@pytest.mark.parametrize("line", [
    "</SHUNT-CODE>", "<SHUNT-CODE>", "  <SHUNT-NOTES>\t", "<<<SHUNT-CODE>>>", "</SHUNT-CODE>>", "</shunt-notes>",
    "SHUNT-CODE", "<<SHUNT-NOTES>\r"])
def test_check_protocol_tags_refuses_tag_look_alike_lines(tmp_path, line):
    code = f"a = 1\n{line}\nb = 2\n".encode()
    assert cw_text.check_protocol_tags(written(tmp_path, code)) == "protocol-tag-in-code"


@pytest.mark.parametrize("line", [
    'print("</SHUNT-CODE>")', "# <SHUNT-CODE> is the tag", "<<<<SHUNT-CODE>", "<SHUNT-CODES>", "x</SHUNT-CODE>"])
def test_check_protocol_tags_allows_lines_that_only_mention_a_tag(tmp_path, line):
    assert cw_text.check_protocol_tags(written(tmp_path, f"{line}\n".encode())) == ""


def test_check_protocol_tags_catches_a_tag_on_the_last_line_without_newline(tmp_path):
    assert cw_text.check_protocol_tags(written(tmp_path, b"x\n</SHUNT-CODE>")) == "protocol-tag-in-code"


def test_cli_strip_invisible_prints_the_raw_bytes_without_newline():
    result = cli("strip-invisible", "--", "-a​b‮")
    assert (result.returncode, result.stdout) == (0, b"-ab")


def test_cli_unsafe_exit_codes():
    assert cli("unsafe", "--", "a​b").returncode == 0
    assert cli("unsafe", "--", "clean").returncode == 10


def test_cli_check_text_prints_the_reason_and_fails(tmp_path):
    result = cli("check-text", written(tmp_path, b"a\x00"))
    assert (result.returncode, result.stdout) == (1, b"nul-bytes\n")
    assert cli("check-text", written(tmp_path, b"fine\n")).returncode == 0


def test_cli_limit_falls_back_to_the_default():
    assert cli("limit", "--", "abc", "262144").stdout == b"262144\n"
    assert cli("limit", "--", "42", "262144").stdout == b"42\n"
