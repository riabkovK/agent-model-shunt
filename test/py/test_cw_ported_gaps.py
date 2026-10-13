"""Behaviours of the removed bash suite (codewrite.bats) that had no pytest twin."""

import os
import shutil
import stat
import subprocess

import pytest

from shunt import cw_inputs, cw_target
from test_cw_parse import reply, run as parse_run
from test_cw_publish import b, code, proj, publish  # noqa: F401  (fixtures)


@pytest.mark.parametrize("raw", [b"a\xc0\x80b", b"a\xed\xa0\x80b", b"a\xf4\x90\x80\x80b"])
def test_parse_rejects_overlong_surrogate_and_out_of_range_utf8(tmp_path, raw):
    (reason, _), _ = parse_run(tmp_path, reply(code=raw))
    assert reason == "invalid-utf8"


def test_parse_accepts_multibyte_utf8_in_code(tmp_path):
    (reason, status), out = parse_run(tmp_path, reply(code="x = 'é日本'".encode()))
    assert (reason, status) == ("ok", 0)
    assert (out / "code").read_bytes() == "x = 'é日本'\n".encode()


def test_publish_keeps_bytes_and_never_sets_an_exec_bit(proj, code):  # noqa: F811
    code.write_bytes("a\r\nb é\r\n".encode())
    code.chmod(0o755)
    os.umask(0o000)
    publish(proj, b"x.txt", code)
    target = proj / "x.txt"
    assert target.read_bytes() == "a\r\nb é\r\n".encode()
    assert stat.S_IMODE(target.stat().st_mode) == 0o644
    assert target.stat().st_nlink == 1


@pytest.mark.parametrize("target", ["a/.git./x", "a/.git /x", "a/.GIT/x", "a/.claude../x", ".env.", "a/.github /x"])
def test_resolve_refuses_denied_names_with_trailing_dots_spaces_or_case(proj, target):  # noqa: F811
    with pytest.raises(cw_target.Refusal):
        cw_target.resolve(b(proj), target.encode())


def test_resolve_accepts_names_with_a_dot_only_inside(proj):  # noqa: F811
    assert cw_target.resolve(b(proj), b"a/b.c/d.e.py").missing


def test_project_root_prefers_claude_project_dir_and_ignores_a_non_directory(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    cwd = tmp_path / "cwd"
    cwd.mkdir()
    old = os.getcwd()
    os.chdir(cwd)
    try:
        assert cw_inputs.project_root({"CLAUDE_PROJECT_DIR": str(real)}) == os.path.realpath(real)
        with_bad = {"CLAUDE_PROJECT_DIR": str(tmp_path / "nope"), "PATH": "/nonexistent"}
        assert cw_inputs.project_root(with_bad) == os.path.realpath(cwd)
    finally:
        os.chdir(old)


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_project_root_uses_the_git_top_level_when_the_variable_is_unset(tmp_path):
    top = tmp_path / "top"
    (top / "sub").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(top)], check=True)
    old = os.getcwd()
    os.chdir(top / "sub")
    try:
        assert cw_inputs.project_root({"PATH": os.environ["PATH"], "HOME": str(tmp_path)}) == os.path.realpath(top)
    finally:
        os.chdir(old)


@pytest.mark.parametrize("name", [".GIT", ".Claude", ".ssh.", ".Config", ".LOCAL", ".Aws"])
def test_project_root_cwd_fallback_below_a_root_list_name_is_refused_in_any_case(tmp_path, name):
    bad = tmp_path / name / "work"
    bad.mkdir(parents=True)
    old = os.getcwd()
    os.chdir(bad)
    try:
        with pytest.raises(cw_inputs.Stop):
            cw_inputs.project_root({"PATH": "/nonexistent"})
    finally:
        os.chdir(old)
