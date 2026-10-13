"""Publish stages of code-write (cw_publish.py): no clobber, no symlink following, rollback."""

import os
import signal
import stat
import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import cw_publish, cw_target

FINAL = b"x.txt"


@pytest.fixture
def proj(tmp_path):
    root = tmp_path / "proj"
    root.mkdir()
    return root


@pytest.fixture
def code(tmp_path):
    path = tmp_path / "code.txt"
    path.write_bytes(b"hello\n")
    return path


def b(path) -> bytes:
    return os.fsencode(path)


def publish(root, rel, code_file, seam=None):
    """The same order as lib/codewrite.sh: resolve, dirs, stage, link."""
    seam = seam or (lambda _name: None)
    found = cw_target.resolve(b(root), rel)
    created: list[bytes] = []
    tmp = b""
    try:
        directory, created = cw_publish.make_dirs(found.ancestor, found.missing)
        seam("after-mkdir")
        tmp = cw_publish.stage_tmp(found.root, directory, found.missing[-1], b(code_file))
        seam("before-link")
        name = found.missing[-1]
        if not cw_publish.link_no_clobber(directory, os.path.basename(tmp), name):
            raise cw_publish.PublishError("not published")
        return directory + b"/" + name
    except BaseException:
        if tmp:
            _unlink(tmp)
        for path in reversed(created):
            try:
                os.rmdir(path)
            except OSError:
                pass
        raise


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def strays(root):
    return [p for p in root.rglob(".shunt-cw.*")]


def test_publish_creates_directories_and_a_0644_file(proj, code):
    os.umask(0o077)
    final = publish(proj, b"a/b/x.txt", code)
    assert final == b(proj / "a/b/x.txt")
    assert (proj / "a/b/x.txt").read_bytes() == b"hello\n"
    assert stat.S_IMODE((proj / "a/b/x.txt").stat().st_mode) == 0o644
    assert stat.S_IMODE((proj / "a/b").stat().st_mode) == 0o755
    assert not strays(proj)


def test_publish_never_overwrites_an_existing_file(proj, code):
    (proj / "x.txt").write_text("mine")
    with pytest.raises(cw_target.Refusal):
        publish(proj, b"x.txt", code)
    assert (proj / "x.txt").read_text() == "mine"


def test_publish_never_clobbers_a_file_created_between_check_and_link(proj, code):
    def seam(name):
        if name == "before-link":
            (proj / "a" / "x.txt").write_text("racer")

    (proj / "a").mkdir()
    with pytest.raises(cw_publish.PublishError):
        publish(proj, b"a/x.txt", code, seam)
    assert (proj / "a" / "x.txt").read_text() == "racer"
    assert not strays(proj)


def test_publish_never_follows_a_symlink_planted_at_the_final_name(proj, code, tmp_path):
    victim = tmp_path / "victim"
    victim.write_text("original")

    def seam(name):
        if name == "before-link":
            (proj / "x.txt").symlink_to(victim)

    with pytest.raises(cw_publish.PublishError):
        publish(proj, b"x.txt", code, seam)
    assert victim.read_text() == "original"
    assert (proj / "x.txt").is_symlink()
    assert not strays(proj)


def test_publish_never_follows_a_dangling_symlink_at_the_final_name(proj, code, tmp_path):
    def seam(name):
        if name == "before-link":
            (proj / "x.txt").symlink_to(tmp_path / "does-not-exist")

    with pytest.raises(cw_publish.PublishError):
        publish(proj, b"x.txt", code, seam)
    assert not (tmp_path / "does-not-exist").exists()


def test_publish_refuses_a_directory_planted_at_the_final_name(proj, code):
    def seam(name):
        if name == "before-link":
            (proj / "x.txt").mkdir()

    with pytest.raises(cw_publish.PublishError):
        publish(proj, b"x.txt", code, seam)
    assert list((proj / "x.txt").iterdir()) == []
    assert not strays(proj)


def test_publish_refuses_a_created_directory_swapped_for_an_outside_symlink(proj, code, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()

    def seam(name):
        if name == "after-mkdir":
            (proj / "a").rmdir()
            (proj / "a").symlink_to(outside)

    with pytest.raises(cw_publish.PublishError):
        publish(proj, b"a/x.txt", code, seam)
    assert list(outside.iterdir()) == []


def test_publish_refuses_a_parent_swapped_for_another_directory_inside_the_root(proj, code):
    (proj / "elsewhere").mkdir()

    def seam(name):
        if name == "after-mkdir":
            (proj / "a").rmdir()
            (proj / "a").symlink_to(proj / "elsewhere")

    with pytest.raises(cw_publish.PublishError, match="changed while publishing"):
        publish(proj, b"a/x.txt", code, seam)
    assert list((proj / "elsewhere").iterdir()) == []


def test_publish_refuses_a_symlinked_parent_that_existed_before(proj, code, tmp_path):
    (tmp_path / "outside").mkdir()
    (proj / "link").symlink_to(tmp_path / "outside")
    with pytest.raises(cw_target.Refusal):
        publish(proj, b"link/x.txt", code)
    assert list((tmp_path / "outside").iterdir()) == []


def test_stage_refuses_a_directory_swapped_after_the_stage_for_a_symlink(proj, code, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    found = cw_target.resolve(b(proj), b"a/x.txt")
    directory, _ = cw_publish.make_dirs(found.ancestor, found.missing)
    tmp = cw_publish.stage_tmp(found.root, directory, b"x.txt", b(code))
    os.unlink(tmp)
    os.rmdir(directory)
    os.symlink(outside, directory)
    assert cw_publish.link_no_clobber(directory, os.path.basename(tmp), b"x.txt") is False
    assert list(outside.iterdir()) == []


def test_link_refuses_when_the_staged_file_was_replaced_by_a_symlink(proj, code, tmp_path):
    target = tmp_path / "secret"
    target.write_text("s")
    tmp = cw_publish.stage_tmp(b(proj), b(proj), b"x.txt", b(code))
    os.unlink(tmp)
    os.symlink(target, tmp)
    assert cw_publish.link_no_clobber(b(proj), os.path.basename(tmp), b"x.txt") is False
    assert not (proj / "x.txt").exists()
    assert target.read_text() == "s"


def test_link_falls_back_to_an_exclusive_copy_without_hard_links(proj, code, monkeypatch):
    def refuse(*_a, **_k):
        raise PermissionError("no hard links here")

    monkeypatch.setattr(os, "link", refuse)
    final = publish(proj, b"sub/x.txt", code)
    assert final == b(proj / "sub/x.txt")
    assert stat.S_IMODE((proj / "sub/x.txt").stat().st_mode) == 0o644
    assert not strays(proj)


def test_fallback_still_refuses_an_existing_name(proj, code, monkeypatch):
    monkeypatch.setattr(os, "link", lambda *_a, **_k: (_ for _ in ()).throw(PermissionError()))

    def seam(name):
        if name == "before-link":
            (proj / "x.txt").write_text("racer")

    with pytest.raises(cw_publish.PublishError):
        publish(proj, b"x.txt", code, seam)
    assert (proj / "x.txt").read_text() == "racer"


def test_make_dirs_rolls_back_the_ones_it_created_when_a_later_name_is_a_file(proj):
    (proj / "a").mkdir()
    (proj / "a" / "d").write_text("file")
    with pytest.raises(cw_publish.PublishError):
        cw_publish.make_dirs(b(proj), [b"a", b"d", b"f.txt"])
    assert (proj / "a").is_dir()
    assert sorted(p.name for p in (proj / "a").iterdir()) == ["d"]
    (proj / "a" / "d").unlink()
    (proj / "a").rmdir()
    with pytest.raises(cw_publish.PublishError):
        cw_publish.make_dirs(b(proj), [b"n1", b"..", b"f.txt"])
    assert list(proj.iterdir()) == []


def test_make_dirs_uses_but_does_not_claim_an_existing_directory(proj):
    (proj / "a").mkdir()
    directory, created = cw_publish.make_dirs(b(proj), [b"a", b"b", b"f.txt"])
    assert directory == b(proj / "a/b")
    assert created == [b(proj / "a/b")]


def test_make_dirs_does_not_follow_a_symlink_in_the_chain(proj, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (proj / "a").symlink_to(outside)
    with pytest.raises(cw_publish.PublishError):
        cw_publish.make_dirs(b(proj), [b"a", b"b", b"f.txt"])
    assert list(outside.iterdir()) == []


def test_stage_refuses_a_denied_parent_and_leaves_nothing(proj, code):
    (proj / ".git").mkdir()
    with pytest.raises(cw_publish.PublishError, match="not allowed"):
        cw_publish.stage_tmp(b(proj), b(proj / ".git"), b"x.txt", b(code))
    assert not strays(proj)


def test_stage_rejects_an_unsafe_temp_name(proj, code):
    for name in (b"evil", b".shunt-cw.a/../b"):
        with pytest.raises(cw_publish.PublishError):
            cw_publish.stage_tmp(b(proj), b(proj), b"x.txt", b(code), name)


def test_stage_refuses_a_preexisting_temp_name_without_touching_it(proj, code, tmp_path):
    victim = tmp_path / "victim"
    victim.write_text("keep")
    (proj / ".shunt-cw.fixed").symlink_to(victim)
    with pytest.raises(cw_publish.PublishError):
        cw_publish.stage_tmp(b(proj), b(proj), b"x.txt", b(code), b".shunt-cw.fixed")
    assert victim.read_text() == "keep"


def test_stage_removes_the_temp_file_when_the_content_cannot_be_written(proj, code, monkeypatch):
    def broken(*_a, **_k):
        raise OSError("disk full")

    monkeypatch.setattr(os, "fsync", broken)
    with pytest.raises(cw_publish.PublishError, match="temporary file"):
        cw_publish.stage_tmp(b(proj), b(proj), b"x.txt", b(code))
    assert not strays(proj)


@pytest.mark.parametrize("content, message", [
    (b"", "empty file"), (b"a\x00b", "nul-bytes"), (b"\xff", "invalid-utf8"), ("‮".encode(), "bidi-controls"),
    (b"a\n<SHUNT-CODE>\n", "protocol-tag-in-code"), (b"a\x0c", "control-characters"),
])
def test_check_code_file_refuses_bad_content(tmp_path, content, message):
    path = tmp_path / "c"
    path.write_bytes(content)
    assert message in cw_publish.check_code_file(b(path))


def test_check_code_file_applies_the_cap(tmp_path, monkeypatch):
    monkeypatch.setenv("SHUNT_CW_MAX_CODE_BYTES", "3")
    path = tmp_path / "c"
    path.write_bytes(b"abcd")
    assert cw_publish.check_code_file(b(path)) == "shunt: refusing to write 4 bytes, the cap is 3."


def run_cli(*args):
    return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "codewrite", *args],
                          capture_output=True, text=True)


def test_cli_stages_round_trip(proj, code):
    made = run_cli("make-dirs", str(proj), "d", "x.txt")
    assert made.returncode == 0
    assert made.stdout.splitlines() == [str(proj / "d"), str(proj / "d")]
    name = ".shunt-cw.cli1"
    staged = run_cli("stage-tmp", str(proj), str(proj / "d"), "x.txt", str(code), name)
    assert staged.stdout.strip() == str(proj / "d" / name)
    linked = run_cli("link", str(proj / "d"), name, "x.txt")
    assert linked.returncode == 0
    assert (proj / "d" / "x.txt").read_bytes() == b"hello\n"
    assert not strays(proj)


def test_cli_link_exits_1_when_the_name_exists(proj, code):
    (proj / "x.txt").write_text("mine")
    name = ".shunt-cw.cli2"
    run_cli("stage-tmp", str(proj), str(proj), "x.txt", str(code), name)
    assert run_cli("link", str(proj), name, "x.txt").returncode == 1
    assert (proj / "x.txt").read_text() == "mine"
    assert not strays(proj)


def test_cli_reports_a_publish_error_on_stdout_with_status_1(proj, code):
    done = run_cli("stage-tmp", str(proj), str(proj / "missing"), "x.txt", str(code), "")
    assert done.returncode == 1
    assert "parent directory" in done.stdout


def test_a_signal_during_staging_removes_the_temp_file(proj, code, monkeypatch):
    def interrupted(*_a, **_k):
        raise cw_publish.Interrupted(143)

    monkeypatch.setattr(os, "fsync", interrupted)
    with pytest.raises(SystemExit) as info:
        cw_publish.stage_tmp(b(proj), b(proj), b"x.txt", b(code))
    assert info.value.code == 143
    assert not strays(proj)


def test_a_signal_while_making_directories_removes_the_ones_created(proj, monkeypatch):
    calls = []

    def interrupted_second_time(fd, mode):
        calls.append(fd)
        if len(calls) == 2:
            raise cw_publish.Interrupted(143)

    monkeypatch.setattr(os, "fchmod", interrupted_second_time)
    with pytest.raises(SystemExit):
        cw_publish.make_dirs(b(proj), [b"a", b"b", b"c", b"x.txt"])
    assert list(proj.iterdir()) == []


def test_a_real_sigterm_makes_the_cli_exit_143_and_leave_nothing(proj, code):
    script = (
        "import os, signal, sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "from shunt import cw_publish\n"
        "cw_publish.rollback_on_signals()\n"
        "real = os.fsync\n"
        "def fsync(fd):\n"
        "    os.kill(os.getpid(), signal.SIGTERM)\n"
        "    real(fd)\n"
        "os.fsync = fsync\n"
        "cw_publish.stage_tmp(sys.argv[2].encode(), sys.argv[2].encode(), b'x.txt', sys.argv[3].encode())\n"
    )
    done = subprocess.run([sys.executable, "-I", "-B", "-c", script, str(SHUNT_MAIN.parent), str(proj), str(code)])
    assert done.returncode == 143
    assert not strays(proj)
