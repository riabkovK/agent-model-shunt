import json
import os
import stat

import pytest

from shunt.jsonio import JsonReadError, read_json, write_json_atomic


def _mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def test_read_json_returns_default_when_file_missing(tmp_path):
    assert read_json(tmp_path / "nope.json", default={"a": 1}) == {"a": 1}


def test_read_json_missing_without_default_returns_none(tmp_path):
    assert read_json(tmp_path / "nope.json") is None


def test_read_json_parses_valid_file(tmp_path):
    p = tmp_path / "f.json"
    p.write_text('{"x": [1, 2]}')

    assert read_json(p) == {"x": [1, 2]}


def test_read_json_invalid_raises_clear_error_naming_path(tmp_path):
    p = tmp_path / "bad.json"
    p.write_text("{not json")

    with pytest.raises(JsonReadError) as exc:
        read_json(p, default={})

    assert str(p) in str(exc.value)


def test_read_json_empty_file_is_invalid(tmp_path):
    p = tmp_path / "empty.json"
    p.write_text("")

    with pytest.raises(JsonReadError):
        read_json(p)


def test_read_json_directory_raises_read_error(tmp_path):
    with pytest.raises(JsonReadError):
        read_json(tmp_path)


def test_write_creates_file_with_mode_600_and_roundtrips(tmp_path):
    p = tmp_path / "providers.json"

    write_json_atomic(p, {"providers": {"a": 1}})

    assert json.loads(p.read_text()) == {"providers": {"a": 1}}
    assert p.read_text().endswith("\n")
    assert _mode(p) == 0o600


def test_write_honours_explicit_mode_regardless_of_umask(tmp_path):
    p = tmp_path / "f.json"
    old = os.umask(0o077)
    try:
        write_json_atomic(p, {}, mode=0o644)
    finally:
        os.umask(old)

    assert _mode(p) == 0o644


def test_write_creates_missing_parent_dirs(tmp_path):
    p = tmp_path / "a" / "b" / "f.json"

    write_json_atomic(p, [1])

    assert json.loads(p.read_text()) == [1]


def test_write_replaces_existing_file_and_tightens_mode(tmp_path):
    p = tmp_path / "f.json"
    p.write_text("{}")
    p.chmod(0o644)

    write_json_atomic(p, {"new": True})

    assert json.loads(p.read_text()) == {"new": True}
    assert _mode(p) == 0o600


def test_unserializable_data_leaves_original_and_no_temp(tmp_path):
    d = tmp_path / "d"
    d.mkdir()
    p = d / "f.json"
    write_json_atomic(p, {"keep": 1})

    with pytest.raises(TypeError):
        write_json_atomic(p, {"bad": object()})

    assert json.loads(p.read_text()) == {"keep": 1}
    assert [x.name for x in d.iterdir()] == ["f.json"]


def test_replace_failure_leaves_original_and_no_temp(tmp_path, monkeypatch):
    d = tmp_path / "d"
    d.mkdir()
    p = d / "f.json"
    write_json_atomic(p, {"keep": 1})

    def boom(*_a, **_k):
        raise OSError("disk gone")

    monkeypatch.setattr(os, "replace", boom)

    with pytest.raises(OSError):
        write_json_atomic(p, {"new": 2})

    monkeypatch.undo()
    assert json.loads(p.read_text()) == {"keep": 1}
    assert [x.name for x in d.iterdir()] == ["f.json"]


def test_fsync_failure_leaves_no_temp(tmp_path, monkeypatch):
    d = tmp_path / "d"
    d.mkdir()
    p = d / "f.json"
    monkeypatch.setattr(os, "fsync", lambda _fd: (_ for _ in ()).throw(OSError("io")))

    with pytest.raises(OSError):
        write_json_atomic(p, {"a": 1})

    monkeypatch.undo()
    assert list(d.iterdir()) == []


def test_write_rejects_nan_and_leaves_no_file(tmp_path):
    d = tmp_path / "d"
    d.mkdir()

    with pytest.raises(ValueError):
        write_json_atomic(d / "f.json", {"x": float("nan")})

    assert list(d.iterdir()) == []


@pytest.mark.parametrize("text", ["1" * 6000, "[" * 200000])
def test_read_json_wraps_digit_limit_and_recursion_errors(tmp_path, text):
    path = tmp_path / "f.json"
    path.write_text(text)
    with pytest.raises(JsonReadError, match="invalid JSON"):
        read_json(path)


def test_read_json_message_echoes_raw_path(tmp_path):
    (tmp_path / "bad.json").write_text("{")
    raw = f"{tmp_path}//./bad.json"
    with pytest.raises(JsonReadError) as info:
        read_json(raw)
    assert raw in str(info.value)
