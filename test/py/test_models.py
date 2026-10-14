import json
import os
import sys
import stat
import subprocess

import pytest

from conftest import REPO_ROOT, SHUNT_MAIN
from shunt import models
from shunt.cli import build_parser


@pytest.fixture
def reg(tmp_path):
    """Registry helpers bound to a temp dir; SHUNT_* env points into it."""
    class Reg:
        file = tmp_path / "models.json"
        agents = tmp_path / "agents"
        prompts = tmp_path / "prompts"
        env = {
            "SHUNT_MODELS_FILE": str(tmp_path / "models.json"),
            "SHUNT_AGENTS_DIR": str(tmp_path / "agents"),
            "SHUNT_PROMPTS_DIR": str(tmp_path / "prompts"),
        }

        def write(self, entries, **top):
            doc = {"version": 1, "active": None, "models": entries, **top}
            self.file.write_text(json.dumps(doc))

        def cli(self, *args):
            env = {**os.environ, **self.env}
            return subprocess.run(
                [sys.executable, "-I", "-B", str(SHUNT_MAIN), "models", *args],
                capture_output=True, text=True, env=env, check=False)

    r = Reg()
    r.prompts.mkdir()
    (r.prompts / "bulk-reader.md").write_text("BULK PROMPT\n")
    (r.prompts / "code-writer.md").write_text("WRITER PROMPT\n")
    return r


# ---- slug

@pytest.mark.parametrize("model_id, core", [
    ("Spark/deepseek-ai/DeepSeek-V4-Flash-0731", "spark-deepseek-ai-deepseek-v4-flash-0731"),
    ("p/a.b", "p-a-b"),
    ("p//x__y", "p-x-y"),
    ("///", ""),
    ("-p/m-", "p-m"),
    ("İstanbul/m", "stanbul-m"),  # only ASCII is lowered, like jq ascii_downcase
])
def test_slug_core(model_id, core):
    assert models.slug_core(model_id) == core


def test_slug_prefixes():
    assert models.slug("P/M") == "shunt-bulk-reader-p-m"
    assert models.code_writer_agent_for("P/M") == "shunt-code-writer-p-m"


# ---- validate

def _reason(reg, entries=None, **top):
    if entries is not None:
        reg.write(entries, **top)
    return models.validate(reg.file)


def test_validate_missing_file(reg):
    assert models.validate(reg.file) == f"models registry not found at {reg.file}"
    assert not models.available(reg.file)


@pytest.mark.parametrize("content", ["not json", "", "null", "false"])
def test_validate_invalid_json(reg, content):
    reg.file.write_text(content)
    assert models.validate(reg.file) == f"models registry at {reg.file} contains invalid JSON."


def test_validate_accepts_empty_models_and_plain_entries(reg):
    assert _reason(reg, []) is None
    assert _reason(reg, [{"id": "p/m", "agent": "a"}, {"id": "p/n"}]) is None
    assert models.available(reg.file)


def test_validate_models_missing_or_not_list_cannot_be_read(reg):
    for doc in ({}, {"models": None}, {"models": ["x"]}, []):
        reg.file.write_text(json.dumps(doc))
        assert models.validate(reg.file) == (
            f"models registry at {reg.file}: cannot read context_tokens and oversize_policy.")


def test_validate_duplicate_ids_lists_each_with_trailing_space(reg):
    reason = _reason(reg, [{"id": "b"}, {"id": "a"}, {"id": "b"}, {"id": "a"}, {"id": "c"}])
    assert reason == f"models registry at {reg.file} has duplicate model id(s): a b "


@pytest.mark.parametrize("roles, fragment", [
    (["bulk-read", "summarize"], 'has unknown role(s): "summarize". Known roles: bulk-read, code-write.'),
    ([], "has an empty roles array."),
    ("bulk-read", "has invalid roles: must be an array of role names."),
    (None, "has invalid roles: must be an array of role names."),
    ([1], "has unknown role(s): 1. Known roles: bulk-read, code-write."),
    ([["bulk-read"]], 'has unknown role(s): ["bulk-read"]. Known roles: bulk-read, code-write.'),
    (["x", "bulk-read", "y"], 'has unknown role(s): "x", "y". Known roles: bulk-read, code-write.'),
])
def test_validate_roles(reg, roles, fragment):
    reason = _reason(reg, [{"id": "p/a", "agent": "a1", "roles": roles}])
    assert reason == f'models registry at {reg.file}: model "p/a" {fragment}'


def test_validate_roles_reports_first_offending_model(reg):
    reason = _reason(reg, [{"id": "p/a", "roles": []}, {"id": "p/b", "roles": 5}])
    assert 'model "p/a"' in reason and "p/b" not in reason


@pytest.mark.parametrize("entries, fragment", [
    ([{"id": "///"}], 'model "///" derives an empty agent name.'),
    ([{"id": "p/x", "agent": "../evil"}],
     'model "p/x" has an invalid agent name "../evil": use lowercase letters, digits and dashes.'),
    ([{"id": "p/x", "agent": "-bad"}], "invalid agent name"),
    ([{"id": "p/a.b"}, {"id": "p/a-b"}],
     'models "p/a.b" and "p/a-b" would share the agent name "shunt-bulk-reader-p-a-b".'),
    ([{"id": "p/x", "agent": "shunt-bulk-reader-p-y"}, {"id": "p/y"}], "would share the agent name"),
    ([{"id": "p/a.b", "agent": "x1"}, {"id": "p/a-b", "agent": "x2"}],
     'models "p/a.b" and "p/a-b" would share the agent name "shunt-code-writer-p-a-b".'),
])
def test_validate_agent_names_rejected(reg, entries, fragment):
    assert fragment in _reason(reg, entries)


def test_validate_agent_names_accepted(reg):
    assert _reason(reg, [{"id": "p/x", "agent": "bulk-reader"}, {"id": "p/y", "agent": "a2"}]) is None
    # The code-writer name is reserved for every model, even one without the role.
    assert "shunt-code-writer-p-a-b" in _reason(reg, [{"id": "p/a.b", "agent": "x1", "roles": ["bulk-read"]},
                                                      {"id": "p/a-b", "agent": "x2"}])
    assert _reason(reg, [{"id": "p/m", "agent": "-"}]) is None  # "-" means derived


@pytest.mark.parametrize("tokens", ["0", "-5", '"100"', "1.5", "1e12", "1e30", "null", "true"])
def test_validate_rejects_bad_context_tokens(reg, tokens):
    reg.file.write_text('{"models":[{"id":"p/a","agent":"a1","context_tokens":%s}]}' % tokens)
    assert models.validate(reg.file) == (
        f'models registry at {reg.file}: model "p/a" has invalid context_tokens: '
        "must be a positive integer below 10^12.")


@pytest.mark.parametrize("tokens", ["1", "128000", "128000.0", "5.0", "999999999999"])
def test_validate_accepts_good_context_tokens(reg, tokens):
    reg.file.write_text('{"models":[{"id":"p/a","agent":"a1","context_tokens":%s}]}' % tokens)
    assert models.validate(reg.file) is None


@pytest.mark.parametrize("policy", ['"bogus"', "1", "null", '""'])
def test_validate_rejects_bad_oversize_policy(reg, policy):
    reg.file.write_text('{"models":[{"id":"p/a","agent":"a1","oversize_policy":%s}]}' % policy)
    assert models.validate(reg.file).endswith(
        'model "p/a" has invalid oversize_policy: must be "map_reduce" or "fail".')


def test_validate_accepts_oversize_policies(reg):
    for policy in ("map_reduce", "fail"):
        assert _reason(reg, [{"id": "p/a", "agent": "a1", "oversize_policy": policy}]) is None


# ---- candidates

def _ids(reg, role="bulk-read"):
    return models.candidates(reg.file, role)


def test_candidates_priority_order_and_active_first(reg):
    reg.write([{"id": "a"}, {"id": "b"}, {"id": "c"}], active="c")
    assert _ids(reg) == ("", ["c", "a", "b"])


def test_candidates_skip_disabled_and_roleless(reg):
    reg.write([{"id": "a", "enabled": False}, {"id": "b", "roles": ["code-write"]},
               {"id": "c", "roles": ["bulk-read"]}, {"id": "d", "enabled": None}], active="a")
    assert _ids(reg) == ("", ["c", "d"])
    assert _ids(reg, "code-write") == ("", ["b", "d"])


def test_candidates_unknown_active_is_reported(reg):
    reg.write([{"id": "a"}], active="ghost")
    assert _ids(reg) == ("ghost", ["a"])


def test_candidates_empty_registry(reg):
    reg.write([])
    assert _ids(reg) == ("", [])


def test_candidates_cli_warns_on_stderr_unless_quiet(reg):
    reg.write([{"id": "a"}], active="ghost")
    loud = reg.cli("candidates", "bulk-read")
    assert loud.stdout == "a\n"
    assert loud.stderr == ("shunt: models registry's active model 'ghost' is not in the models list; "
                           "falling back to priority order.\n")
    quiet = reg.cli("candidates", "bulk-read", "quiet")
    assert quiet.stdout == "a\n" and quiet.stderr == ""


def test_candidates_missing_registry_fails_with_exit_2(reg):
    result = reg.cli("candidates", "bulk-read")
    assert result.returncode == 2 and result.stdout == ""


# ---- lookups

def test_agent_for(reg):
    reg.write([{"id": "p/a", "agent": "named"}, {"id": "P/M"}, {"id": "p/e", "agent": ""}])
    assert models.agent_for(reg.file, "p/a") == "named"
    assert models.agent_for(reg.file, "P/M") == "shunt-bulk-reader-p-m"
    assert models.agent_for(reg.file, "p/e") == "shunt-bulk-reader-p-e"
    assert models.agent_for(reg.file, "nope") == ""
    assert reg.cli("agent-for", "nope").stdout == ""
    assert reg.cli("agent-for", "--", "p/a").stdout == "named\n"


def test_thinking_lookups(reg):
    reg.write([{"id": "on", "thinking": True, "thinking_options": {"a": 1}},
               {"id": "off", "thinking_off_options": {"reasoningEffort": "none", "n": [1, "é"]}},
               {"id": "bare"}])
    assert models.thinking_for(reg.file, "on") == ["true"]
    assert models.thinking_for(reg.file, "off") == ["false"]
    assert models.thinking_for(reg.file, "nope") == []
    assert models.thinking_options_for(reg.file, "on") == ['{"a":1}']
    assert models.thinking_options_for(reg.file, "bare") == ["null"]
    assert models.thinking_options_for(reg.file, "off", "thinking_off_options") == [
        '{"reasoningEffort":"none","n":[1,"é"]}']
    assert models.thinking_options_for(reg.file, "bare", "thinking_off_options") == ["null"]


def test_has_role(reg):
    reg.write([{"id": "both"}, {"id": "bulk", "roles": ["bulk-read"]}])
    assert models.has_role(reg.file, "both", "code-write")
    assert models.has_role(reg.file, "bulk", "bulk-read")
    assert not models.has_role(reg.file, "bulk", "code-write")
    assert not models.has_role(reg.file, "ghost", "bulk-read")
    assert reg.cli("has-role", "bulk", "code-write").returncode == 1
    assert reg.cli("has-role", "both", "code-write").returncode == 0


def test_has_role_unreadable_registry_is_false(reg):
    assert not models.has_role(reg.file, "x", "bulk-read")


# ---- thinking block and agent files

def test_thinking_block_off_options_only_while_off(reg):
    reg.write([{"id": "m", "thinking": False, "thinking_options": {"on": 1},
                "thinking_off_options": {"reasoningEffort": "none"}}])
    assert models.thinking_block(reg.file, "m") == "reasoningEffort: none"


def test_thinking_block_on_uses_thinking_options_and_json_scalars(reg):
    reg.write([{"id": "m", "thinking": True, "thinking_options": {"budget": 8, "flag": True, "t": {"a": 1}},
                "thinking_off_options": {"x": "y"}}])
    assert models.thinking_block(reg.file, "m") == 'budget: 8\nflag: true\nt: {"a":1}'


def test_thinking_block_empty_cases(reg):
    reg.write([{"id": "m"}, {"id": "n", "thinking": True, "thinking_options": None}])
    assert models.thinking_block(reg.file, "m") == ""
    assert models.thinking_block(reg.file, "n") == ""
    assert models.thinking_block(reg.file, "ghost") == ""
    assert reg.cli("thinking-block", "m").stdout == ""


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def test_materialize_writes_bulk_reader_file(reg):
    reg.write([{"id": "p/m", "agent": "shunt-bulk-reader-p-m", "roles": ["bulk-read"]}])
    result = reg.cli("materialize", "p/m")
    assert result.returncode == 0, result.stderr
    text = (reg.agents / "shunt-bulk-reader-p-m.md").read_text()
    assert text.startswith("---\ndescription: Precise, read-only code analyst for delegated bulk-read "
                           "questions.\nmode: primary\nmodel: p/m\ntools:\n  read: true\n  bash: false\n")
    assert text.endswith("  dependency-analyzer: false\n---\n\nBULK PROMPT\n")
    assert _mode(reg.agents / "shunt-bulk-reader-p-m.md") == 0o600
    assert not (reg.agents / "shunt-code-writer-p-m.md").exists()


def test_materialized_agent_files_end_with_the_text_of_the_real_prompts(reg):
    real = REPO_ROOT / "prompts"
    reg.env["SHUNT_PROMPTS_DIR"] = str(real)
    reg.write([{"id": "acme/m1", "agent": "shunt-bulk-reader-acme-m1"}])
    result = reg.cli("materialize", "acme/m1")
    assert result.returncode == 0, result.stderr
    for name, prompt in (("shunt-bulk-reader-acme-m1", "bulk-reader.md"), ("shunt-code-writer-acme-m1", "code-writer.md")):
        assert (reg.agents / f"{name}.md").read_text().endswith((real / prompt).read_text())


def test_materialize_writes_code_writer_with_temperature_and_thinking(reg):
    reg.write([{"id": "p/m", "agent": "bulk", "thinking": True, "thinking_options": {"effort": "high"}}])
    assert reg.cli("materialize", "p/m").returncode == 0
    writer = (reg.agents / "shunt-code-writer-p-m.md").read_text()
    assert writer.startswith("---\ndescription: Tool-less code generator for delegated code-write calls.\n"
                             "mode: primary\nmodel: p/m\ntemperature: 0.2\neffort: high\ntools:\n  \"*\": false\n")
    assert writer.endswith("---\n\nWRITER PROMPT\n")
    bulk = (reg.agents / "bulk.md").read_text()
    assert "model: p/m\neffort: high\ntools:\n" in bulk
    assert _mode(reg.agents / "shunt-code-writer-p-m.md") == 0o600


def test_materialize_removes_stale_code_writer(reg):
    reg.write([{"id": "p/m", "agent": "bulk", "roles": ["bulk-read"]}])
    reg.agents.mkdir()
    (reg.agents / "shunt-code-writer-p-m.md").write_text("stale")
    assert reg.cli("materialize", "p/m").returncode == 0
    assert not (reg.agents / "shunt-code-writer-p-m.md").exists()


def test_materialize_missing_prompt_changes_nothing(reg):
    reg.write([{"id": "p/m", "agent": "bulk"}])
    (reg.prompts / "code-writer.md").unlink()
    result = reg.cli("materialize", "p/m")
    assert result.returncode == 1
    assert result.stderr == (f"shunt: the role prompt file {reg.prompts}/code-writer.md is missing or "
                             "unreadable, nothing was changed.\n")
    assert not reg.agents.exists()


def test_materialize_unknown_model_errors(reg):
    reg.write([])
    result = reg.cli("materialize", "ghost")
    assert result.returncode == 1
    assert result.stderr == "shunt: no registered agent name for model 'ghost'.\n"


def test_materialize_refuses_unsafe_agent_name(reg):
    reg.write([{"id": "p/m", "agent": "../evil", "roles": ["bulk-read"]}])
    result = reg.cli("materialize", "p/m")
    assert result.returncode == 1 and "unsafe agent name" in result.stderr
    assert not (reg.file.parent / "evil.md").exists()


def test_require_prompts_roles(reg):
    assert reg.cli("require-prompts").returncode == 0
    assert reg.cli("require-prompts", "code-write").returncode == 0
    (reg.prompts / "code-writer.md").unlink()
    assert reg.cli("require-prompts", "bulk-read").returncode == 0
    assert reg.cli("require-prompts", "code-write").returncode == 1


# ---- cli

def test_validate_cli_prints_reason_on_stdout_with_exit_1(reg):
    reg.file.write_text("not json")
    result = reg.cli("validate")
    assert result.returncode == 1
    assert result.stdout == f"shunt: models registry at {reg.file} contains invalid JSON.\n"
    assert result.stderr == ""


def test_validate_and_available_cli_success_is_silent(reg):
    reg.write([{"id": "p/m"}])
    for cmd in ("validate", "available"):
        result = reg.cli(cmd)
        assert (result.returncode, result.stdout, result.stderr) == (0, "", "")


def test_available_cli_exit_1_when_invalid(reg):
    reg.file.write_text("nope")
    assert reg.cli("available").returncode == 1


def test_models_paths_default_to_home_config(tmp_path, monkeypatch):
    monkeypatch.delenv("SHUNT_MODELS_FILE", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    cfg = tmp_path / ".config" / "agent-model-shunt"
    cfg.mkdir(parents=True)
    (cfg / "models.json").write_text('{"models":[{"id":"x"}]}')
    result = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "models", "candidates",
                             "bulk-read"], capture_output=True, text=True, check=False)
    assert result.stdout == "x\n"


def test_models_parser_registered():
    args = build_parser().parse_args(["models", "slug", "a/b"])
    assert args.models_command == "slug" and args.id == "a/b"


# ---- fixes after review 1-3

BAD_CHARS = ["\n", "\r", "\x00", "\x1b", "\x7f", "\t"]


@pytest.mark.parametrize("char", BAD_CHARS)
def test_validate_rejects_control_char_in_id(reg, char):
    reg.write([{"id": f"p/m{char}x: y"}])
    reason = models.validate(reg.file)
    assert reason and "control character" in reason and "its id" in reason
    assert "\n" not in reason and "\x1b" not in reason
    out = reg.cli("validate")
    assert out.returncode == 1 and out.stdout.startswith("shunt: models registry at ")


@pytest.mark.parametrize("field", ["thinking_options", "thinking_off_options"])
@pytest.mark.parametrize("where", ["key", "value"])
def test_validate_rejects_control_char_in_thinking_options(reg, field, where):
    opts = {"k\nx": "v"} if where == "key" else {"k": "v\nthinking: injected"}
    reg.write([{"id": "p/m", field: opts}])
    reason = models.validate(reg.file)
    assert reason and "control character" in reason and field in reason


def test_validate_accepts_colon_slash_and_json_scalars_in_options(reg):
    reg.write([{"id": "p/m:free", "thinking_options": {"a/b": "x: y", "n": 1, "o": {"q": "\n"}}}])
    assert models.validate(reg.file) is None


def test_materialize_refuses_control_char_without_validate(reg):
    reg.write([{"id": "p/m", "thinking": True, "thinking_options": {"k": "v\nmodel: evil"}}])
    result = reg.cli("materialize", "p/m")
    assert result.returncode == 1
    assert result.stderr.startswith("shunt: refusing to render")
    assert not reg.agents.exists() or not list(reg.agents.iterdir())


def test_materialize_refuses_control_char_in_id(reg):
    reg.write([{"id": "p/m\nx"}])
    result = reg.cli("materialize", "p/m\nx")
    assert result.returncode == 1 and "refusing to render" in result.stderr


def test_validate_reserves_code_writer_name_of_model_without_the_role(reg):
    reg.write([{"id": "a", "roles": ["bulk-read"]}, {"id": "b", "agent": "shunt-code-writer-a"}])
    reason = models.validate(reg.file)
    assert reason and 'would share the agent name "shunt-code-writer-a"' in reason


def test_materialize_never_deletes_another_models_bulk_agent_file(reg):
    reg.write([{"id": "a", "roles": ["bulk-read"]}, {"id": "b", "agent": "shunt-code-writer-a"}])
    reg.agents.mkdir()
    victim = reg.agents / "shunt-code-writer-a.md"
    victim.write_text("b's agent")
    assert reg.cli("materialize", "a").returncode == 0
    assert victim.read_text() == "b's agent"


def test_materialize_still_removes_a_stale_code_writer(reg):
    reg.write([{"id": "a", "roles": ["bulk-read"]}])
    reg.agents.mkdir()
    stale = reg.agents / "shunt-code-writer-a.md"
    stale.write_text("stale")
    assert reg.cli("materialize", "a").returncode == 0
    assert not stale.exists()


def test_validate_messages_echo_the_raw_env_path(reg, tmp_path):
    env = {**os.environ, "SHUNT_MODELS_FILE": "./nope//x.json"}
    result = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "models", "validate"],
                            capture_output=True, text=True, env=env, cwd=tmp_path, check=False)
    assert result.stdout == "shunt: models registry not found at ./nope//x.json\n"
    reg.file.write_text("nope")
    assert models.validate("./a//b/../models.json") == "models registry not found at ./a//b/../models.json"


def test_require_prompts_message_echoes_the_raw_prompts_dir(reg):
    env = {**os.environ, "SHUNT_PROMPTS_DIR": "./nope//p"}
    result = subprocess.run([sys.executable, "-I", "-B", str(SHUNT_MAIN), "models", "require-prompts"],
                            capture_output=True, text=True, env=env, check=False)
    assert result.returncode == 1
    assert "./nope//p/bulk-reader.md is missing" in result.stderr


def test_require_prompts_accepts_double_dash(reg):
    assert reg.cli("require-prompts", "--").returncode == 0
    assert reg.cli("require-prompts", "--", "code-write").returncode == 0
    (reg.prompts / "code-writer.md").unlink()
    assert reg.cli("require-prompts", "--", "code-write").returncode == 1


@pytest.mark.parametrize("content", ["", "nope", "{", '{"models": 3}', '{"models": [1]}', "1" * 6000,
                                     "[" * 200000, '{"models":' + "[" * 200000],
                         ids=["empty", "nonjson", "open-brace", "models-int", "models-nonobject",
                              "digit-limit", "deep-array", "deep-models"])
def test_available_exits_0_or_1_never_2_for_odd_registries(reg, content):
    reg.file.write_text(content)
    assert reg.cli("available").returncode == 1
    assert reg.cli("validate").returncode == 1
    assert "Traceback" not in reg.cli("validate").stderr


def test_candidates_ignore_a_disabled_active_model_without_a_warning(reg):
    reg.write([{"id": "p/first"}, {"id": "p/second", "enabled": False}], active="p/second")
    assert _ids(reg) == ("", ["p/first"])


def test_candidates_warn_about_an_unknown_active_model_even_when_no_model_has_the_role(reg):
    reg.write([{"id": "p/reader", "roles": ["bulk-read"]}], active="p/missing")
    assert _ids(reg, "code-write") == ("p/missing", [])


def test_candidates_skip_an_active_model_lacking_the_role_without_a_warning(reg):
    reg.write([{"id": "p/first"}, {"id": "p/reader", "roles": ["bulk-read"]}, {"id": "p/third"}], active="p/reader")
    assert _ids(reg, "code-write") == ("", ["p/first", "p/third"])


# ---- role_thinking

def _validate_role_thinking(reg, value):
    reg.write([{"id": "p/m", "role_thinking": value}])
    return models.validate(reg.file)


@pytest.mark.parametrize("value,fragment", [
    ([True], "invalid role_thinking: must be a JSON object"),
    ("on", "invalid role_thinking: must be a JSON object"),
    ({"thinker": True}, 'unknown role "thinker"'),
    ({"code-write": "on"}, "must be true or false"),
    ({"bulk-read": None}, "must be true or false"),
])
def test_validate_rejects_a_bad_role_thinking(reg, value, fragment):
    reason = _validate_role_thinking(reg, value)
    assert reason is not None and 'model "p/m"' in reason and fragment in reason


def test_validate_accepts_a_good_role_thinking(reg):
    assert _validate_role_thinking(reg, {"bulk-read": False, "code-write": True}) is None
    assert _validate_role_thinking(reg, {}) is None


def test_role_thinking_renders_a_different_block_per_agent_file(reg):
    reg.write([{"id": "p/m", "agent": "bulk-m", "thinking": False,
                "thinking_options": {"effort": "high"}, "thinking_off_options": {"effort": "none"},
                "role_thinking": {"code-write": True}}])
    assert models.thinking_block(reg.file, "p/m") == "effort: none"
    assert models.thinking_block(reg.file, "p/m", "bulk-read") == "effort: none"
    assert models.thinking_block(reg.file, "p/m", "code-write") == "effort: high"
    models.materialize_agent(reg.file, reg.agents, reg.prompts, "p/m")
    assert "\neffort: none\n" in (reg.agents / "bulk-m.md").read_text()
    assert "\neffort: high\n" in (reg.agents / "shunt-code-writer-p-m.md").read_text()


def test_thinking_for_is_role_aware(reg):
    reg.write([{"id": "p/m", "thinking": False, "role_thinking": {"code-write": True}}])
    assert models.thinking_for(reg.file, "p/m") == ["false"]
    assert models.thinking_for(reg.file, "p/m", "bulk-read") == ["false"]
    assert models.thinking_for(reg.file, "p/m", "code-write") == ["true"]
    assert reg.cli("thinking-for", "p/m", "code-write").stdout == "true\n"
    assert reg.cli("thinking-for", "p/m").stdout == "false\n"


# ---- adversarial round 2

def test_agent_named_like_its_own_code_writer_file_is_refused(reg):
    # The writer render would overwrite the bulk agent file, so validate refuses the name.
    reg.write([{"id": "p/m", "agent": "shunt-code-writer-p-m"}])
    reason = models.validate(reg.file)
    assert reason is not None and "shunt-code-writer-p-m" in reason
