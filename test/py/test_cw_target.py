"""Where a model-written file may land (cw_target.py), plus the CLI group."""

import os
import subprocess
import sys

import pytest

from conftest import SHUNT_MAIN
from shunt import cw_target


@pytest.fixture
def proj(tmp_path):
    root = tmp_path / "proj"
    root.mkdir()
    return root


def reason(root, target):
    with pytest.raises(cw_target.Refusal) as info:
        cw_target.resolve(os.fsencode(root), os.fsencode(target))
    return str(info.value)


def place(root, target):
    return cw_target.resolve(os.fsencode(root), os.fsencode(target))


def cli(*args):
    return subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "codewrite", *args], capture_output=True)


@pytest.mark.parametrize("path,hit", [
    (".env", b".env"), (".ENV.local", b".env.local"), ("a/b.env", b"b.env"), ("home/.ssh/id_rsa", b".ssh"),
    ("x/.git./y", b".git"), ("x/.git /y", b".git"), ("p/.claude/s.json", b".claude"),
    ("a/id_ed25519.pub", b"id_ed25519.pub"), ("a/server.PEM", b"server.pem"), ("a/x.tfstate.backup", b"x.tfstate.backup"),
    ("h/.bash_history", b".bash_history"), ("h/.config/gcloud/x", b".config/gcloud"),
    ("h/.config/OpenCode/x", b".config/opencode"), ("h/.local/share/opencode/auth.json", b".local/share/opencode"),
    ("h/.m2/settings.xml", b".m2/settings.xml"), ("a/credentials.json", b"credentials.json"),
    ("a/secrets.YAML", b"secrets.yaml"), ("a/wrangler.toml", b"wrangler.toml"), ("a/x.gpg", b"x.gpg"),
    ("a/.dev.vars.prod", b".dev.vars.prod"), ("a/firebase-adminsdk-abc.json", b"firebase-adminsdk-abc.json"),
    ("//.ssh", b".ssh")])
def test_sensitive_component_names_credential_and_state_stores(path, hit):
    assert cw_target.sensitive_component(path.encode()) == hit


@pytest.mark.parametrize("path", [
    "src/app.py", "a/.config/other", "a/config/gcloud", "local/share/opencode", "a/envelope.txt", "a//b", "", "a/./b",
    "docs/keys.md", "a/.gitignore"])
def test_sensitive_component_is_none_for_ordinary_paths(path):
    assert cw_target.sensitive_component(path.encode()) is None


@pytest.mark.parametrize("target,part", [
    ("a/.git/x", ".git"), (".github/w.yml", ".github"), ("a/.GIT./x", ".git"), ("...", "..."), ("a/.../x", "..."),
    ("docs/CLAUDE.md", "claude.md"), ("AGENTS.md", "agents.md"), ("a/Makefile", "makefile"),
    ("a/opencode.json", "opencode.json"), ("a/conftest.py", "conftest.py"), ("a/Jenkinsfile ", "jenkinsfile"),
    ("a/.envrc", ".envrc")])
def test_find_denied_names_dotted_and_steering_components(target, part):
    assert cw_target.find_denied(target.encode()) == part.encode()


def test_find_denied_is_none_for_a_normal_path():
    assert cw_target.find_denied(b"src/pkg/mod.py") is None


def test_find_denied_root_uses_a_short_list_without_the_dot_rule():
    assert cw_target.find_denied_root(b"home/u/.cache/proj") is None
    assert cw_target.find_denied_root(b"home/u/.SSH/x") == b".ssh"
    assert cw_target.root_denied_hit(b"/home/u/.aws/proj") == b".aws"
    assert cw_target.root_denied_hit(b"/home/u/.password-store/x") == b".password-store"


def test_resolve_accepts_a_new_file_in_a_new_directory(proj):
    found = place(proj, "src/new/mod.py")
    assert found.resolved == os.fsencode(proj.resolve()) + b"/src/new/mod.py"
    assert found.missing == (b"src", b"new", b"mod.py")


def test_resolve_accepts_an_absolute_target_under_the_root(proj):
    assert place(proj, str(proj / "a.py")).resolved.endswith(b"/proj/a.py")


@pytest.mark.parametrize("target,text", [
    ("a/../.git/x", "'.git' is not allowed"), ("a/../b", "'..' component"), ("../x", "'..' component"), ("a/./b", "'.' component"),
    ("a//b", "empty component"), ("a/", "ends with a slash"), ("", "target is empty"),
    ("a/.git/x", "'.git' is not allowed"), (".env", "'.env' is not allowed"), ("a/\nb", "control characters"),
    ("a/b‮.py", "invisible Unicode"), ("a/z​w.py", "invisible Unicode"), ("a\tb", "control characters"),
    ("a/" + "x" * 5000, "longer than 4096"), ("/etc/new.txt", "outside the project root"), ("/etc/hosts", "not a new path inside the project root")])
def test_resolve_refuses_bad_targets(proj, target, text):
    assert text in reason(proj, target)


def test_resolve_refuses_an_existing_file_dir_and_dangling_symlink(proj):
    (proj / "f.py").write_text("x")
    (proj / "d").mkdir()
    (proj / "dangling").symlink_to(proj / "nowhere")
    for name in ("f.py", "d", "dangling"):
        assert "already exists" in reason(proj, name)


def test_resolve_refuses_a_symlink_that_leaves_the_root(proj, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (proj / "link").symlink_to(outside)
    assert "outside the project root" in reason(proj, "link/new.py")


def test_resolve_refuses_a_symlink_to_a_sensitive_directory_inside_the_root(proj):
    (proj / ".git").mkdir()
    (proj / "innocent").symlink_to(proj / ".git")
    assert "'.git' is not allowed" in reason(proj, "innocent/hook.py")


def test_resolve_refuses_a_symlinked_name_that_looks_sensitive_even_if_it_points_somewhere_safe(proj):
    (proj / "safe").mkdir()
    (proj / ".claude").symlink_to(proj / "safe")
    assert "'.claude' is not allowed" in reason(proj, ".claude/x.py")


def test_resolve_refuses_a_symlink_that_is_a_file_ancestor(proj):
    (proj / "file").write_text("x")
    assert "cannot be entered" in reason(proj, "file/sub.py") or "not a directory" in reason(proj, "file/sub.py")


def test_resolve_accepts_an_absolute_alias_of_the_root_and_prints_the_canonical_path(proj, tmp_path):
    alias = tmp_path / "alias"
    alias.symlink_to(proj)
    assert place(proj, str(alias / "new.py")).resolved == os.fsencode(proj.resolve()) + b"/new.py"


def test_resolve_applies_the_lexical_rule_to_the_whole_path_of_an_alias_spelling(proj, tmp_path):
    hidden = tmp_path / ".hid"
    hidden.mkdir()
    (hidden / "alias").symlink_to(proj)
    assert "'.hid' is not allowed" in reason(proj, str(hidden / "alias" / "new.py"))


def test_resolve_refuses_an_alias_of_a_sensitive_directory_inside_the_root(proj, tmp_path):
    (proj / ".ssh").mkdir()
    alias = tmp_path / "alias"
    alias.symlink_to(proj / ".ssh")
    assert "'.ssh' is not allowed" in reason(proj, str(alias / "k.py"))


def test_resolve_a_root_inside_a_dotted_directory_is_allowed_below_the_root(tmp_path):
    root = tmp_path / ".hidden" / "proj"
    root.mkdir(parents=True)
    assert place(root, "a.py").resolved.endswith(b"/.hidden/proj/a.py")


@pytest.mark.parametrize("root,text", [
    ("relative/dir", "must be an absolute path"), ("/", "filesystem root"), ("/no/such/dir-x", "is not a directory"),
    ("/tmp/a\nb", "control characters")])
def test_resolve_refuses_a_bad_root(root, text):
    assert text in reason(root, "a.py")


def test_resolve_refuses_a_root_that_is_a_file(tmp_path):
    file = tmp_path / "file"
    file.write_text("x")
    assert "is not a directory" in reason(file, "a.py")


def test_check_placement_compares_whole_components(proj):
    sibling = proj.parent / "proj-evil"
    sibling.mkdir()
    with pytest.raises(cw_target.Refusal, match="outside"):
        cw_target.check_placement(os.fsencode(proj), os.fsencode(sibling), b"x.py")


def test_check_placement_rejects_a_denied_tail_and_accepts_the_root_itself(proj):
    root = os.fsencode(proj)
    with pytest.raises(cw_target.Refusal, match=r"'\.git'"):
        cw_target.check_placement(root, root, b".git/x")
    cw_target.check_placement(root, root, b"ok.py")


def test_canon_dir_resolves_symlinks_and_rejects_files_and_missing_paths(proj):
    (proj / "link").symlink_to(proj)
    (proj / "f").write_text("x")
    assert cw_target.canon_dir(os.fsencode(proj / "link")) == os.fsencode(proj.resolve())
    assert cw_target.canon_dir(os.fsencode(proj / "f")) is None
    assert cw_target.canon_dir(os.fsencode(proj / "nope")) is None


def test_cli_resolve_prints_root_ancestor_resolved_and_missing(proj):
    result = cli("resolve", "--", str(proj), "a/b.py")
    base = str(proj.resolve())
    assert result.returncode == 0
    assert result.stdout.decode().split("\n") == [base, base, base + "/a/b.py", "a", "b.py", ""]


def test_cli_resolve_prints_the_refusal_and_exits_1(proj):
    result = cli("resolve", "--", str(proj), "../x")
    assert (result.returncode, result.stdout) == (1, b"the path has a '..' component\n")


def test_cli_sensitive_exits_1_when_clean_and_prints_the_hit_otherwise():
    assert cli("sensitive", "--", "src/a.py").returncode == 10
    hit = cli("sensitive", "--", "a/.AWS/c")
    assert (hit.returncode, hit.stdout) == (0, b".aws\n")


def test_cli_root_hit_and_canon_dir(proj):
    assert cli("root-hit", "--", "/home/u/work").returncode == 10
    assert cli("root-hit", "--", "/home/u/.kube/x").stdout == b".kube\n"
    assert cli("canon-dir", "--", str(proj / "missing")).returncode == 10


def test_cli_placement_failure_prints_the_reason(proj):
    result = cli("placement", "--", str(proj), str(proj.parent), "x.py")
    assert (result.returncode, result.stdout) == (1, b"it resolves outside the project root\n")


def test_bash_wrappers_fail_closed_when_the_interpreter_is_broken():
    lib = SHUNT_MAIN.parents[2] / "scripts" / "lib" / "codewrite.sh"
    script = (f'source "{lib}"; SHUNT_PYTHON=false; '
              '_shunt_cw_has_unsafe_chars clean && echo unsafe-hit; '
              'shunt_cw_sensitive_component src/a.py >/dev/null && echo sensitive-hit; '
              '_shunt_cw_check_text /dev/null || echo text-refused')
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True).stdout.split()
    assert out == ["unsafe-hit", "sensitive-hit", "text-refused"]
