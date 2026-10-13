"""Response protocol split and lexical path normalization (cw_parse.py), plus their CLI."""

import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import cw_parse


def reply(notes=b"why", code=b"print(1)", extra_before=b"", extra_between=b"", extra_after=b""):
    return (extra_before + b"<SHUNT-NOTES>\n" + notes + b"\n</SHUNT-NOTES>\n" + extra_between
            + b"<SHUNT-CODE>\n" + code + b"\n</SHUNT-CODE>\n" + extra_after)


def run(tmp_path, data: bytes):
    response = tmp_path / "response"
    response.write_bytes(data)
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    result = cw_parse.parse(str(response).encode(), str(out).encode())
    return result, out


def test_parse_splits_notes_and_code(tmp_path):
    # Arrange / Act
    (reason, status), out = run(tmp_path, reply(b"note a\nnote b", b"x = 1\ny = 2"))
    # Assert
    assert (reason, status) == ("ok", 0)
    assert (out / "notes").read_bytes() == b"note a\nnote b\n"
    assert (out / "code").read_bytes() == b"x = 1\ny = 2\n"


def test_parse_tolerates_crlf_tags_and_blank_lines_around_sections(tmp_path):
    data = b"\n\r\n<SHUNT-NOTES>\r\nn\r\n</SHUNT-NOTES>\r\n\n<SHUNT-CODE>\r\nc\r\n</SHUNT-CODE>\r\n \n"
    (reason, _), out = run(tmp_path, data)
    assert reason == "ok"
    assert (out / "code").read_bytes() == b"c\r\n"


def test_parse_handles_a_reply_without_a_final_newline(tmp_path):
    (reason, _), out = run(tmp_path, b"<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n<SHUNT-CODE>\nc\n</SHUNT-CODE>")
    assert reason == "ok"
    assert (out / "code").read_bytes() == b"c\n"


@pytest.mark.parametrize("data, expected", [
    (b"", "empty-response"),
    (b"just text\n", "missing-notes-delimiter"),
    (b"<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n", "missing-code-delimiter"),
    (b"<SHUNT-NOTES>\nn\n<SHUNT-CODE>\nc\n", "missing-closing-tag"),
    (reply() + b"<SHUNT-NOTES>\n", "duplicate-notes-delimiter"),
    (reply() + b"<SHUNT-CODE>\n", "duplicate-code-delimiter"),
    (reply() + b"</SHUNT-CODE>\n", "duplicate-closing-tag"),
    (b"<SHUNT-CODE>\nc\n</SHUNT-CODE>\n<SHUNT-NOTES>\nn\n</SHUNT-NOTES>\n", "out-of-order"),
    (reply(extra_before=b"hello\n"), "text-before-delimiter"),
    (reply(extra_between=b"hello\n"), "text-between-sections"),
    (reply(extra_after=b"hello\n"), "text-after-closing-tag"),
    (reply(notes=b"", code=b" \n\t"), "empty-code"),
    (reply(code=b"a\x00b"), "nul-bytes"),
    (reply(code=b"a\xffb"), "invalid-utf8"),
    (reply(code=b"a\x01b"), "control-characters"),
    (reply(code=b"a\x0cb"), "control-characters"),
    (reply(code=b"a\rb"), "control-characters"),
    (reply(code="a​b".encode()), "invisible-characters"),
    (reply(code="a‮b".encode()), "bidi-controls"),
    (reply(code=b"x\n</shunt-code>\ny"), "protocol-tag-in-code"),
    (reply(code=b"x\n</SHUNT-CODE>\ny"), "duplicate-closing-tag"),
    (reply(code=b"x\n<<SHUNT-CODE>>\ny"), "protocol-tag-in-code"),
])
def test_parse_refuses_a_malformed_reply_and_leaves_no_files(tmp_path, data, expected):
    (reason, status), out = run(tmp_path, data)
    assert (reason, status) == (expected, cw_parse.EXIT_UNUSABLE)
    assert not (out / "code").exists()
    assert not (out / "notes").exists()


def test_parse_reports_a_deliberate_refusal_with_notes_only(tmp_path):
    (reason, status), out = run(tmp_path, reply(b"cannot do that", b""))
    assert (reason, status) == ("deliberate-refusal", cw_parse.EXIT_REFUSAL)
    assert (out / "notes").read_bytes() == b"cannot do that\n"


def test_parse_strips_only_an_outer_fence_and_keeps_inner_ones(tmp_path):
    code = b"\n```python\na = 1\n```text\ninner\n```\nb = 2\n```\n\n"
    (reason, _), out = run(tmp_path, reply(code=code))
    assert reason == "ok"
    assert (out / "code").read_bytes() == b"a = 1\n```text\ninner\n```\nb = 2\n"


def test_parse_keeps_text_whose_first_line_is_a_fence_but_has_no_closing_one(tmp_path):
    (reason, _), out = run(tmp_path, reply(code=b"```python\nx = 1"))
    assert reason == "ok"
    assert (out / "code").read_bytes() == b"```python\nx = 1\n"


def test_parse_does_not_treat_a_two_backtick_line_as_a_fence(tmp_path):
    (_, _), out = run(tmp_path, reply(code=b"``\nx\n``"))
    assert (out / "code").read_bytes() == b"``\nx\n``\n"


def test_parse_enforces_the_size_caps_from_the_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("SHUNT_CW_MAX_CODE_BYTES", "10")
    (reason, status), _ = run(tmp_path, reply(code=b"x" * 11))
    assert (reason, status) == ("oversize", cw_parse.EXIT_UNUSABLE)


def test_parse_enforces_the_notes_cap(tmp_path, monkeypatch):
    monkeypatch.setenv("SHUNT_CW_MAX_NOTES_BYTES", "5")
    (reason, _), _ = run(tmp_path, reply(notes=b"123456"))
    assert reason == "oversize"


def test_parse_ignores_a_non_numeric_cap(tmp_path, monkeypatch):
    monkeypatch.setenv("SHUNT_CW_MAX_CODE_BYTES", "1e3")
    (reason, _), _ = run(tmp_path, reply(code=b"x" * 2000))
    assert reason == "ok"


def test_parse_removes_stale_output_files_first(tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    (out / "code").write_bytes(b"stale")
    (reason, _), out = run(tmp_path, b"nonsense\n")
    assert reason == "missing-notes-delimiter"
    assert not (out / "code").exists()


def test_cli_parse_prints_the_reason_and_exits_with_the_status(tmp_path):
    response = tmp_path / "r"
    response.write_bytes(reply(b"n", b""))
    out = tmp_path / "o"
    out.mkdir()
    done = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "codewrite", "parse", str(response), str(out)],
                          capture_output=True)
    assert (done.returncode, done.stdout) == (10, b"deliberate-refusal\n")


def test_cli_parse_exits_2_when_the_response_is_missing(tmp_path):
    done = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "codewrite", "parse",
                           str(tmp_path / "nope"), str(tmp_path)], capture_output=True)
    assert done.returncode == 2


@pytest.mark.parametrize("raw, expected", [
    (b"a/./b//c", b"a/b/c"), (b"a/b/../c", b"a/c"), (b"a/..", b"."), (b"./a", b"a"), (b"../a", b"../a"),
    (b"a/../../b", b"../b"), (b"../..", b"../.."), (b"/a/../..", b"/"), (b"/../etc", b"/etc"), (b"/", b"/"),
    (b"a/b/", b"a/b/"), (b"", b""), (b"a\nb/../c", b"a\nb/../c"), (b"a/\xe2\x80\xaeb/../c", b"a/\xe2\x80\xaeb/../c"),
    (b"..a/..", b"."), (b"a/.../b", b"a/.../b"),
])
def test_normalize_path_is_purely_lexical(raw, expected):
    assert cw_parse.normalize_path(raw) == expected
