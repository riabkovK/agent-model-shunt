"""The shunt-models command line (models_cli.py), run in process on isolated files."""

import json
import threading

import pytest

from conftest import REPO_ROOT
from shunt import models_cli, providers_write
from shunt.lockfile import file_lock

BREAKER_FAR_FUTURE = 9999999999


class Cli:
    """A shunt-models session: files under tmp_path, calls through models_cli.main, output via capsys."""

    def __init__(self, tmp_path, monkeypatch, capsys):
        self.root = tmp_path
        self.capsys = capsys
        self.monkeypatch = monkeypatch
        self.models = tmp_path / "models.json"
        self.providers = tmp_path / "providers.json"
        self.agents = tmp_path / "agents"
        self.breaker = tmp_path / "breaker-state.json"
        self.opencode_home = tmp_path / "opencode"
        self.opencode_home.mkdir()
        for name, path in (("SHUNT_MODELS_FILE", self.models), ("SHUNT_PROVIDERS_FILE", self.providers),
                           ("SHUNT_AGENTS_DIR", self.agents), ("SHUNT_BREAKER_STATE_FILE", self.breaker),
                           ("SHUNT_OPENCODE_CONFIG_HOME", self.opencode_home),
                           ("SHUNT_PROMPTS_DIR", REPO_ROOT / "prompts")):
            monkeypatch.setenv(name, str(path))
        monkeypatch.setenv("SHUNT_PROC_VERSION_FILE", str(tmp_path / "no-proc-version"))

    def run(self, *args):
        code = models_cli.main(list(args))
        captured = self.capsys.readouterr()
        self.out, self.err = captured.out, captured.err
        return code

    def ok(self, *args):
        assert self.run(*args) == 0, self.err
        return self.out

    def fail(self, *args, code=1):
        assert self.run(*args) == code, (self.out, self.err)
        return self.err

    def opencode(self, *names):
        (self.opencode_home / "opencode.json").write_text(json.dumps({"provider": {n: {"models": {}} for n in names}}))

    def add(self, *specs):
        """Add models of provider p. A spec is an id, optionally followed by a space and the roles."""
        self.opencode("p")
        for spec in specs:
            self.ok("add", *spec.split())

    def doc(self):
        return json.loads(self.models.read_text())

    def entry(self, index=0):
        return self.doc()["models"][index]

    def edit(self, change):
        doc = self.doc()
        change(doc)
        self.models.write_text(json.dumps(doc))

    def agent_text(self, name):
        return (self.agents / f"{name}.md").read_text()

    def set_providers(self, doc):
        self.providers.write_text(json.dumps(doc))


@pytest.fixture
def cli(tmp_path, monkeypatch, capsys):
    return Cli(tmp_path, monkeypatch, capsys)


@pytest.fixture
def populated(cli):
    cli.add("p/one", "p/two")
    return cli


# ---------------------------------------------------------------- add

def test_add_creates_the_registry_and_materializes_an_agent(cli):
    cli.opencode("p")
    out = cli.ok("add", "p/m")
    entry = cli.entry()
    assert out == "shunt: added 'p/m' (agent: shunt-bulk-reader-p-m, roles: bulk-read,code-write).\n"
    assert entry["id"] == "p/m" and entry["enabled"] is True and entry["thinking_off_options"] is None
    assert (cli.agents / f"{entry['agent']}.md").is_file()
    assert (cli.agents / "shunt-code-writer-p-m.md").is_file()


def test_add_refuses_a_provider_missing_from_opencode_json(cli):
    cli.opencode()
    err = cli.fail("add", "missing-provider/m")
    assert err == ("shunt: provider 'missing-provider' not found in "
                   f"{cli.opencode_home}/opencode.json. Add it to your OpenCode config first, or configure it for the "
                   "HTTP transport with: shunt-models provider set missing-provider --transport http "
                   "--base-url <url> --key <type>\n")


def test_add_refuses_when_there_is_no_opencode_json(cli):
    assert "not found in" in cli.fail("add", "p/m")


def test_add_for_an_http_provider_needs_nothing_from_opencode_json(cli):
    cli.set_providers({"version": 1, "providers": {"h": {"transport": "http", "base_url": "https://h.test/v1"}}})
    cli.ok("add", "h/m")
    assert cli.entry()["id"] == "h/m"


def test_add_refuses_a_duplicate_and_keeps_the_registry(populated):
    before = populated.models.read_text()
    populated.fail("add", "p/one")
    assert populated.models.read_text() == before


def test_add_without_an_id_prints_usage(cli):
    assert cli.fail("add") == ("shunt: usage: shunt-models add <provider/model> [<role>[,<role>...]] "
                               "(roles: bulk-read code-write)\n")


@pytest.mark.parametrize("roles,expected", [
    (None, ["bulk-read", "code-write"]),
    ("code-write", ["code-write"]),
    ("code-write,bulk-read,code-write", ["code-write", "bulk-read"]),
])
def test_add_records_the_roles(cli, roles, expected):
    cli.opencode("p")
    cli.ok("add", "p/m", *([roles] if roles else []))
    assert cli.entry()["roles"] == expected


@pytest.mark.parametrize("roles,message", [("bulk_read", "unknown role"), ("bulk-read,", "empty role")])
def test_add_refuses_bad_roles_before_touching_anything(cli, roles, message):
    cli.opencode("p")
    assert message in cli.fail("add", "p/m", roles)
    assert not cli.models.exists() and not cli.agents.exists()


def test_add_with_only_bulk_read_makes_no_code_writer_agent(cli):
    cli.opencode("p")
    cli.ok("add", "p/m", "bulk-read")
    assert (cli.agents / "shunt-bulk-reader-p-m.md").is_file()
    assert not (cli.agents / "shunt-code-writer-p-m.md").exists()


def test_add_with_a_missing_prompt_dir_leaves_the_registry_unwritten(cli, monkeypatch, tmp_path):
    cli.opencode("p")
    monkeypatch.setenv("SHUNT_PROMPTS_DIR", str(tmp_path / "no-prompts"))
    assert "prompt" in cli.fail("add", "p/m")
    assert not cli.models.exists()


def test_add_needs_code_writer_prompt_only_for_the_code_write_role(cli, monkeypatch, tmp_path):
    cli.opencode("p")
    prompts = tmp_path / "only-reader"
    prompts.mkdir()
    (prompts / "bulk-reader.md").write_text("You read.\n")
    monkeypatch.setenv("SHUNT_PROMPTS_DIR", str(prompts))
    cli.ok("add", "p/n", "bulk-read")
    assert cli.models.is_file()
    cli.models.unlink()
    assert "code-writer.md" in cli.fail("add", "p/n", "bulk-read,code-write")
    assert not cli.models.exists()


def test_a_failing_provider_file_stops_add(cli):
    cli.providers.write_text("not json")
    cli.fail("add", "p/m")
    assert not cli.models.exists()


# ---------------------------------------------------------------- remove

def test_remove_drops_the_model_and_its_agent_files(populated):
    one = populated.entry(0)["agent"]
    out = populated.ok("remove", "p/one")
    assert out == "shunt: removed 'p/one'.\n"
    assert [m["id"] for m in populated.doc()["models"]] == ["p/two"]
    assert not (populated.agents / f"{one}.md").exists()
    assert not (populated.agents / "shunt-code-writer-p-one.md").exists()
    assert (populated.agents / "shunt-bulk-reader-p-two.md").is_file()


def test_remove_drops_the_breaker_state_of_the_model_only(populated):
    state = {"version": 1, "models": {
        "p/one": {"failures": 1, "cooldown_until": 0},
        "p/one#code-write": {"failures": 3, "cooldown_until": BREAKER_FAR_FUTURE},
        "p/two#code-write": {"failures": 2, "cooldown_until": 0}}}
    populated.breaker.write_text(json.dumps(state))
    populated.ok("remove", "p/one")
    assert list(json.loads(populated.breaker.read_text())["models"]) == ["p/two#code-write"]


def test_remove_works_without_a_breaker_file_or_an_agent_file(populated):
    (populated.agents / f"{populated.entry(0)['agent']}.md").unlink()
    populated.ok("remove", "p/one")
    assert not populated.breaker.exists()


def test_remove_of_the_last_model_leaves_a_valid_empty_registry(cli):
    cli.add("p/only")
    cli.ok("remove", "p/only")
    assert cli.doc()["models"] == []
    assert "no delegate models configured" in cli.ok("status")
    cli.ok("add", "p/again")


def test_remove_clears_active_when_removing_the_active_model(populated):
    populated.ok("activate", "p/one")
    populated.ok("remove", "p/one")
    assert populated.doc().get("active") is None


def test_remove_reports_an_unknown_model_and_a_missing_registry(cli):
    assert cli.fail("remove", "p/x") == f"shunt: no models registry at {cli.models}.\n"
    cli.add("p/one")
    assert cli.fail("remove", "p/x") == "shunt: model 'p/x' is not in the registry.\n"
    assert cli.fail("remove") == "shunt: usage: shunt-models remove <provider/model>\n"


# ---------------------------------------------------------------- reorder, activate, enable, disable

def test_reorder_moves_a_model_to_the_one_based_position(populated):
    out = populated.ok("reorder", "p/two", "1")
    assert out == "shunt: moved 'p/two' to position 1.\n"
    assert [m["id"] for m in populated.doc()["models"]] == ["p/two", "p/one"]


@pytest.mark.parametrize("args,message", [
    (("p/one",), "usage: shunt-models reorder <provider/model> <1-based position>"),
    (("p/one", "x"), "position must be a positive integer."),
    (("p/one", "-1"), "position must be a positive integer."),
    (("p/one", "1.5"), "position must be a positive integer."),
    (("p/nope", "1"), "model 'p/nope' is not in the registry."),
])
def test_reorder_refusals(populated, args, message):
    assert populated.fail("reorder", *args) == f"shunt: {message}\n"


def test_activate_sets_the_active_model(populated):
    assert populated.ok("activate", "p/two") == "shunt: activated 'p/two'.\n"
    assert populated.doc()["active"] == "p/two"


def test_activate_refuses_an_unknown_and_a_disabled_model(populated):
    assert "not in the registry" in populated.fail("activate", "p/zzz")
    populated.ok("disable", "p/one")
    assert "disabled" in populated.fail("activate", "p/one")
    assert "usage: shunt-models activate" in populated.fail("activate")


def test_disable_and_enable_flip_one_flag_and_keep_everything_else(populated):
    populated.ok("activate", "p/one")
    agent = populated.entry(0)["agent"]
    assert populated.ok("disable", "p/one") == "shunt: disabled 'p/one'.\n"
    assert populated.entry(0)["enabled"] is False and populated.entry(1)["enabled"] is True
    assert populated.doc()["active"] == "p/one" and (populated.agents / f"{agent}.md").is_file()
    assert populated.ok("enable", "p/one") == "shunt: enabled 'p/one'.\n"
    assert populated.entry(0)["enabled"] is True


def test_enable_and_disable_refuse_unknown_ids_and_missing_arguments(populated):
    for verb in ("enable", "disable"):
        assert "not in the registry" in populated.fail(verb, "p/nope")
        assert populated.fail(verb) == f"shunt: usage: shunt-models {verb} <provider/model>\n"


def test_an_entry_without_an_enabled_field_counts_as_enabled(populated):
    def drop(doc):
        del doc["models"][0]["enabled"]
    populated.edit(drop)
    populated.ok("disable", "p/one")
    assert populated.entry(0)["enabled"] is False
    populated.edit(drop)
    populated.ok("enable", "p/one")
    assert populated.entry(0)["enabled"] is True


# ---------------------------------------------------------------- request-body

def test_request_body_sets_and_clears(cli):
    cli.add("p/one")
    out = cli.ok("request-body", "p/one", '{"temperature":0.2}')
    assert out == "shunt: request body for 'p/one' set.\n"
    assert cli.entry()["request_body"] == {"temperature": 0.2}
    assert "cleared" in cli.ok("request-body", "p/one", "--clear")
    assert "request_body" not in cli.entry()


def test_request_body_role_entries_merge_and_vanish_when_empty(cli):
    cli.add("p/one")
    out = cli.ok("request-body", "p/one", "--role", "bulk-read", '{"reasoning_effort":"none"}')
    assert out.startswith("shunt: request body for 'p/one' (role bulk-read) ")
    cli.ok("request-body", "p/one", "--role", "code-write", '{"temperature":0.1}')
    assert cli.entry()["role_request_body"] == {"bulk-read": {"reasoning_effort": "none"},
                                                "code-write": {"temperature": 0.1}}
    cli.ok("request-body", "p/one", "--role", "bulk-read", "--clear")
    assert cli.entry()["role_request_body"] == {"code-write": {"temperature": 0.1}}
    cli.ok("request-body", "p/one", "--role", "code-write", "--clear")
    assert "role_request_body" not in cli.entry()


USAGE_BODY = ("shunt: usage: shunt-models request-body <provider/model> [--role <bulk-read|code-write>] "
              "<json-object|--clear>\n")


@pytest.mark.parametrize("args,message", [
    (("p/one", "[1]"), "shunt: request body must be a JSON object: [1]\n"),
    (("p/one", "nope"), "shunt: request body must be a JSON object: nope\n"),
    (("p/one", "--role", "thinker", '{"a":1}'), "shunt: unknown role 'thinker' (roles: bulk-read code-write).\n"),
    (("p/zzz", '{"a":1}'), "shunt: model 'p/zzz' is not in the registry.\n"),
    ((), USAGE_BODY),
    (("p/one",), USAGE_BODY),
    (("p/one", "--role"), USAGE_BODY),
    (("p/one", "--role", "bulk-read"), USAGE_BODY),
    (("p/one", '{"a":1}', "extra"), USAGE_BODY),
])
def test_request_body_refusals_change_nothing(cli, args, message):
    cli.add("p/one")
    before = cli.models.read_text()
    assert cli.fail("request-body", *args) == message
    assert cli.models.read_text() == before


# ---------------------------------------------------------------- thinking

USAGE_THINKING = ("shunt: usage: shunt-models thinking <provider/model> <on|off> [--role <bulk-read|code-write>] "
                  "[options-json]\n"
                  "       shunt-models thinking <provider/model> --role <bulk-read|code-write> --clear\n")


def test_thinking_on_sets_the_flag_and_renders_options_into_both_agent_files(cli):
    cli.add("p/m")
    out = cli.ok("thinking", "p/m", "on", '{"reasoningEffort":"high"}')
    assert out == "shunt: thinking for 'p/m' set to on.\n"
    assert cli.entry()["thinking"] is True and cli.entry()["thinking_options"] == {"reasoningEffort": "high"}
    for name in ("shunt-bulk-reader-p-m", "shunt-code-writer-p-m"):
        assert "\nreasoningEffort: high\n" in cli.agent_text(name)


def test_thinking_off_clears_the_flag_and_options(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "on", '{"reasoningEffort":"high"}')
    cli.ok("thinking", "p/m", "off")
    assert cli.entry()["thinking"] is False and cli.entry()["thinking_options"] is None
    assert "reasoningEffort" not in cli.agent_text("shunt-bulk-reader-p-m")


def test_thinking_off_options_are_stored_and_rendered_while_off(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "off", '{"reasoningEffort":"none"}')
    assert cli.entry()["thinking_off_options"] == {"reasoningEffort": "none"}
    for name in ("shunt-bulk-reader-p-m", "shunt-code-writer-p-m"):
        assert "\nreasoningEffort: none\n" in cli.agent_text(name)


def test_thinking_off_without_options_keeps_them_and_an_empty_object_clears_them(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "off", '{"reasoningEffort":"none"}')
    cli.ok("thinking", "p/m", "off")
    assert cli.entry()["thinking_off_options"] == {"reasoningEffort": "none"}
    cli.ok("thinking", "p/m", "off", "{}")
    assert cli.entry()["thinking_off_options"] is None
    assert "reasoningEffort" not in cli.agent_text("shunt-bulk-reader-p-m")
    assert "reasoningEffort" not in cli.agent_text("shunt-code-writer-p-m")


def test_thinking_on_keeps_off_options_but_does_not_render_them(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "off", '{"reasoningEffort":"none"}')
    cli.ok("thinking", "p/m", "on", '{"reasoningEffort":"high"}')
    assert cli.entry()["thinking_off_options"] == {"reasoningEffort": "none"}
    text = cli.agent_text("shunt-bulk-reader-p-m")
    assert "\nreasoningEffort: none\n" not in text and "\nreasoningEffort: high\n" in text
    cli.ok("thinking", "p/m", "off")
    assert "\nreasoningEffort: none\n" in cli.agent_text("shunt-code-writer-p-m")


def test_thinking_off_works_on_an_entry_without_the_off_options_field(cli):
    cli.add("p/m")
    cli.edit(lambda doc: doc["models"][0].pop("thinking_off_options"))
    cli.ok("thinking", "p/m", "off")
    cli.ok("thinking", "p/m", "off", '{"reasoningEffort":"none"}')
    assert cli.entry()["thinking_off_options"] == {"reasoningEffort": "none"}


@pytest.mark.parametrize("args,message", [
    (("p/m", "maybe"), "shunt: thinking state must be 'on' or 'off'.\n"),
    (("p/m", "on", "not json"), "valid JSON"),
    (("p/m", "off", "not json"), "valid JSON"),
    (("p/m", "off", '["none"]'), "JSON object"),
    (("p/m", "off", '"none"'), "JSON object"),
    (("p/m", "off", "null"), "JSON object"),
    (("p/unknown", "on"), "shunt: model 'p/unknown' is not in the registry.\n"),
    (("p/m",), USAGE_THINKING),
])
def test_thinking_refusals_leave_the_registry_alone(cli, args, message):
    cli.add("p/m")
    before = cli.models.read_text()
    assert message in cli.fail("thinking", *args)
    assert cli.models.read_text() == before


# ---------------------------------------------------------------- roles

def test_roles_sets_the_order_and_leaves_the_rest_alone(populated):
    populated.ok("activate", "p/two")
    out = populated.ok("roles", "p/one", "code-write,bulk-read")
    assert out == "shunt: roles for 'p/one' set to code-write,bulk-read.\n"
    assert populated.entry(0)["roles"] == ["code-write", "bulk-read"]
    assert populated.entry(1)["roles"] == ["bulk-read", "code-write"]
    assert populated.doc()["active"] == "p/two"


def test_roles_drops_duplicates(populated):
    populated.ok("roles", "p/one", "bulk-read,bulk-read")
    assert populated.entry(0)["roles"] == ["bulk-read"]


def test_roles_registry_feeds_the_candidates(populated):
    from shunt import models
    populated.ok("roles", "p/one", "code-write")
    assert models.candidates(str(populated.models), "bulk-read")[1] == ["p/two"]
    assert models.candidates(str(populated.models), "code-write")[1] == ["p/one", "p/two"]


@pytest.mark.parametrize("roles,message", [
    ("bulk-read,summarize", "summarize"),
    (",", "empty role"),
    ("bulk-read,", "empty role"),
    ("bulk-read\ncode-write", "single comma-separated line"),
])
def test_roles_refuses_bad_lists_and_keeps_the_registry(populated, roles, message):
    before = populated.models.read_text()
    assert message in populated.fail("roles", "p/one", roles)
    assert populated.models.read_text() == before


def test_roles_usage_and_missing_registry_or_entry(cli):
    assert "usage" in cli.fail("roles")
    assert "usage" in cli.fail("roles", "p/one")
    assert "usage" in cli.fail("roles", "p/one", "")
    assert "no models registry" in cli.fail("roles", "p/one", "bulk-read")
    cli.add("p/one")
    assert "not in the registry" in cli.fail("roles", "p/missing", "bulk-read")


def test_roles_with_a_missing_prompt_dir_changes_nothing(cli, monkeypatch, tmp_path):
    cli.add("p/m bulk-read")
    before = cli.models.read_text()
    monkeypatch.setenv("SHUNT_PROMPTS_DIR", str(tmp_path / "no-prompts"))
    assert "prompt" in cli.fail("roles", "p/m", "bulk-read,code-write")
    assert cli.models.read_text() == before


def test_roles_repairs_a_registry_invalid_only_because_of_a_bad_roles_value(cli):
    cli.add("p/one")
    cli.edit(lambda doc: doc["models"][0].update(roles=["bulk_read"]))
    out = cli.ok("roles", "p/one", "bulk-read")
    assert "roles for 'p/one' set to bulk-read." in out and cli.err == ""
    assert cli.entry()["roles"] == ["bulk-read"]


def test_roles_warns_when_the_registry_stays_invalid(cli):
    cli.add("p/one", "p/two")
    cli.edit(lambda doc: doc["models"][1].update(roles=["bulk_read"]))
    cli.ok("roles", "p/one", "bulk-read")
    assert cli.err.startswith("shunt: warning, the registry is still invalid: shunt: models registry at ")
    assert "unknown role" in cli.err


def test_roles_drop_and_restore_the_code_writer_agent(cli):
    cli.add("p/m")
    writer, reader = cli.agents / "shunt-code-writer-p-m.md", cli.agents / "shunt-bulk-reader-p-m.md"
    cli.ok("roles", "p/m", "bulk-read")
    assert not writer.exists() and reader.is_file()
    cli.ok("roles", "p/m", "bulk-read,code-write")
    assert writer.is_file()


def test_roles_of_a_code_write_only_model_keeps_the_agent_files_consistent(cli):
    cli.add("p/m bulk-read")
    cli.ok("roles", "p/m", "code-write")
    assert (cli.agents / "shunt-code-writer-p-m.md").is_file()


# ---------------------------------------------------------------- list, status, sync

def test_list_prints_ids_and_marks_the_active_one(populated):
    populated.ok("activate", "p/two")
    assert populated.ok("list") == "p/one\np/two (active)\n"


def test_list_and_status_explain_a_missing_registry_as_legacy_mode(cli):
    expected = f"shunt: no models registry at {cli.models} (legacy single-agent mode).\n"
    assert cli.ok("list") == expected
    assert cli.ok("status") == expected


def test_list_and_status_explain_an_invalid_registry(cli):
    cli.models.write_text(json.dumps({"version": 1, "active": None,
                                      "models": [{"id": "p/one", "agent": "a", "roles": ["bulk_read"]}]}))
    for verb in ("status", "list"):
        out = cli.ok(verb)
        assert "unknown role" in out and "bulk_read" in out
        assert out.endswith(" Delegate calls use the legacy single agent until it is fixed.\n")


def test_status_rows_name_the_state_of_each_model(populated):
    populated.ok("thinking", "p/two", "off", '{"reasoningEffort":"none"}')
    populated.ok("roles", "p/two", "code-write")
    populated.ok("activate", "p/one")
    populated.ok("disable", "p/one")
    lines = populated.ok("status").splitlines()
    assert lines[0] == ("p/one\tshunt-bulk-reader-p-one\tdisabled\tthinking=false\tthinking_off=none\t"
                        "roles=bulk-read,code-write\tactive (skipped, disabled)")
    assert lines[1] == ("p/two\tshunt-bulk-reader-p-two\tenabled\tthinking=false\tthinking_off=set\t"
                        "roles=code-write\t")


def test_status_first_choice_is_the_active_model_else_the_next_enabled_one(populated):
    populated.ok("activate", "p/two")
    assert "shunt: first choice: p/two\n" in populated.ok("status")
    populated.ok("activate", "p/one")
    populated.ok("disable", "p/one")
    assert "shunt: first choice: p/two\n" in populated.ok("status")


def test_status_says_so_when_nothing_can_be_read(populated):
    populated.ok("disable", "p/one")
    populated.ok("disable", "p/two")
    out = populated.ok("status")
    assert "shunt: no enabled models (large reads are not redirected).\n" in out
    assert "first choice" not in out.replace("code-write first choice", "")


def test_status_names_the_two_first_choices_separately(cli):
    cli.add("p/reader bulk-read", "p/writer code-write")
    cli.ok("activate", "p/reader")
    lines = cli.ok("status").splitlines()
    assert "shunt: first choice: p/reader" in lines
    assert "shunt: code-write first choice: p/writer" in lines


def test_status_without_a_bulk_read_or_code_write_model(cli):
    cli.add("p/m code-write")
    assert ("shunt: no enabled model has the bulk-read role (large reads are not redirected).\n"
            in cli.ok("status"))
    cli.ok("roles", "p/m", "bulk-read")
    out = cli.ok("status")
    assert "shunt: no enabled model has the code-write role (code-write is unavailable).\n" in out
    assert "code-write first choice" not in out


def test_status_shows_the_code_write_breaker_of_each_model_with_that_role(populated, monkeypatch):
    populated.ok("roles", "p/two", "bulk-read")
    populated.breaker.write_text(json.dumps(
        {"version": 1, "models": {"p/one#code-write": {"failures": 3, "cooldown_until": BREAKER_FAR_FUTURE}}}))
    monkeypatch.setenv("SHUNT_NOW_EPOCH", "1000")
    out = populated.ok("status")
    assert "shunt: code-write breaker p/one: failures=3 open=true\n" in out
    assert "code-write breaker p/two" not in out


def test_status_warns_once_about_an_active_model_missing_from_the_registry(populated):
    populated.edit(lambda doc: doc.update(active="p/missing"))
    populated.ok("status")
    assert populated.err.count("falling back to priority order") == 1


def test_sync_recreates_missing_agent_files(populated):
    agent = populated.agents / f"{populated.entry(0)['agent']}.md"
    agent.unlink()
    out = populated.ok("sync")
    assert agent.is_file()
    assert out == "shunt: re-materialized 'p/one'.\nshunt: re-materialized 'p/two'.\n"


def test_sync_creates_a_code_writer_for_a_registry_from_before_roles(cli):
    cli.models.write_text(json.dumps({"version": 1, "active": None, "models": [
        {"id": "p/m", "agent": "shunt-bulk-reader-p-m", "enabled": True}]}))
    cli.ok("sync")
    assert (cli.agents / "shunt-code-writer-p-m.md").is_file()


def test_sync_removes_the_code_writer_of_a_model_without_the_role(cli):
    cli.add("p/m")
    cli.edit(lambda doc: doc["models"][0].update(roles=["bulk-read"]))
    cli.ok("sync")
    assert not (cli.agents / "shunt-code-writer-p-m.md").exists()


def test_sync_needs_a_registry(cli):
    assert cli.fail("sync") == f"shunt: no models registry at {cli.models}.\n"


# ---------------------------------------------------------------- set-context, detect-context, oversize-policy

def test_set_context_stores_it_and_resets_the_breaker(populated):
    populated.breaker.write_text(json.dumps({"version": 1, "models": {"p/one": {"failures": 3, "cooldown_until": 5}}}))
    out = populated.ok("set-context", "p/one", "131072")
    assert out == "shunt: context_tokens for 'p/one' set to 131072.\n"
    assert populated.entry(0)["context_tokens"] == 131072
    assert json.loads(populated.breaker.read_text())["models"] == {}


@pytest.mark.parametrize("tokens", ["0", "-5", "1.5", "abc", "0123", "1" * 13])
def test_set_context_refuses_bad_numbers(populated, tokens):
    err = populated.fail("set-context", "p/one", tokens)
    assert err == "shunt: tokens must be a positive integer of at most 12 digits.\n"
    assert "context_tokens" not in populated.entry(0)


def test_set_context_usage_and_unknown_model(populated):
    assert "usage: shunt-models set-context" in populated.fail("set-context", "p/one")
    assert "not in the registry" in populated.fail("set-context", "p/zzz", "5")


def test_set_context_warns_when_the_breaker_state_is_unreadable(populated):
    populated.breaker.write_text("garbage")
    out = populated.ok("set-context", "p/one", "100")
    assert "set to 100." in out
    assert "warning, could not reset the breaker state of 'p/one'." in populated.err


def test_oversize_policy_sets_and_clears_and_resets_the_breaker(populated):
    populated.breaker.write_text(json.dumps({"version": 1, "models": {"p/one": {"failures": 3, "cooldown_until": 5}}}))
    assert populated.ok("oversize-policy", "p/one", "fail") == "shunt: oversize_policy for 'p/one' set to fail.\n"
    assert populated.entry(0)["oversize_policy"] == "fail"
    assert json.loads(populated.breaker.read_text())["models"] == {}
    out = populated.ok("oversize-policy", "p/one", "--clear")
    assert out == "shunt: oversize_policy for 'p/one' cleared (map_reduce applies).\n"
    assert "oversize_policy" not in populated.entry(0)


@pytest.mark.parametrize("args", [("p/one", "nope"), ("p/one",), ("", "fail")])
def test_oversize_policy_usage(populated, args):
    assert populated.fail("oversize-policy", *args) == (
        "shunt: usage: shunt-models oversize-policy <provider/model> <map_reduce|fail|--clear>\n")


@pytest.fixture
def detect_world(populated, http_server):
    populated.set_providers({"version": 1, "providers": {"p": {
        "transport": "http", "base_url": http_server.url + "/v1", "key": {"type": "none"}}}})
    return populated, http_server


def test_detect_context_prints_the_provider_value_and_writes_it_on_request(detect_world):
    cli, server = detect_world
    server.script("/v1/models/one", body={"id": "one", "context_length": 65536})
    assert cli.ok("detect-context", "p/one") == "65536\n"
    assert "context_tokens" not in cli.entry(0)
    assert cli.ok("detect-context", "p/one", "--write") == (
        "shunt: context_tokens for 'p/one' set to 65536.\n65536\n")
    assert cli.entry(0)["context_tokens"] == 65536


def test_detect_context_reports_not_found_and_changes_nothing(detect_world):
    cli, _server = detect_world
    err = cli.fail("detect-context", "p/one", "--write")
    assert err == ("shunt: could not detect the context window of 'p/one' from its provider. "
                   "Enter it yourself: shunt-models set-context p/one <tokens>\n")
    assert "context_tokens" not in cli.entry(0)


def test_detect_context_reports_a_rejected_key_with_exit_3(detect_world):
    cli, server = detect_world
    server.script("/v1/models/one", status=401, body="no")
    server.script("/v1/models", status=401, body="no")
    err = cli.fail("detect-context", "p/one", code=3)
    assert err == ("shunt: auth failed for the provider of 'p/one' (the key was rejected with 401 or 403): "
                   "re-enter the key through /model-config.\n")


def test_detect_context_usage_and_unknown_model(populated):
    assert "usage: shunt-models detect-context <provider/model> [--write]" in populated.fail("detect-context")
    assert "usage: shunt-models detect-context" in populated.fail("detect-context", "p/one", "--wrong")
    assert "not in the registry" in populated.fail("detect-context", "p/zzz")


# ---------------------------------------------------------------- providers

HTTP = {"transport": "http", "base_url": "https://h.test/v1"}


def test_provider_set_creates_an_entry_and_names_the_key_step(cli):
    out = cli.ok("provider", "set", "h", "--transport", "http", "--base-url", "https://h.test/v1", "--key", "keyring")
    assert out.splitlines()[0] == "shunt: provider 'h' saved (transport http, key keyring)."
    assert out.splitlines()[1].startswith("shunt: enter the key through /model-config (it opens a password window), "
                                          "or without a desktop: ! ")
    assert out.endswith("scripts/shunt-models key set h. Never paste it into chat.\n")
    entry = json.loads(cli.providers.read_text())["providers"]["h"]
    assert entry == {**HTTP, "key": {"type": "keyring"}, "healthcheck": True}


def test_provider_set_keeps_unspecified_fields_and_takes_a_healthcheck_flag(cli):
    cli.ok("provider", "set", "h", "--transport", "http", "--base-url", "https://h.test/v1", "--key", "env:H_KEY")
    out = cli.ok("provider", "set", "h", "--healthcheck", "off")
    assert out == "shunt: provider 'h' saved (transport http, key env).\n"
    assert json.loads(cli.providers.read_text())["providers"]["h"] == {
        **HTTP, "key": {"type": "env", "ref": "H_KEY"}, "healthcheck": False}


@pytest.mark.parametrize("args,message", [
    (("",), models_cli._PROVIDER_SET_USAGE),
    (("bad name",), models_cli._PROVIDER_SET_USAGE),
    (("h", "--transport"), models_cli._PROVIDER_SET_USAGE),
    (("h", "--bogus", "x"), models_cli._PROVIDER_SET_USAGE),
    (("h", "--transport", ""), "--transport needs a non-empty value."),
    (("h", "--healthcheck", ""), "--healthcheck needs a non-empty value."),
    (("h", "--healthcheck", "maybe"), "--healthcheck must be on or off."),
    (("h", "--transport", "grpc"), "--transport must be one of: http opencode."),
    (("h", "--base-url", "ftp://x"), "--base-url must start with http:// or https://."),
    (("h", "--base-url", "no-scheme"), "--base-url must start with http:// or https://."),
    (("h", "--base-url", "https://u:p@x"),
     "--base-url is malformed: it needs a host and must not contain user:password@, whitespace or control characters."),
    (("h", "--key", "env:1bad"), "--key env:<VARNAME> needs a valid environment variable name."),
    (("h", "--transport", "http"), "provider 'h': transport http needs a base_url (--base-url http://... or https://...)."),
    (("h", "--base-url", "https://h.test"), "provider 'h' is new: --transport is required."),
])
def test_provider_set_refusals(cli, args, message):
    assert cli.fail("provider", "set", *args) == f"shunt: {message}\n"
    assert not cli.providers.exists()


def test_provider_set_never_echoes_a_key_pasted_as_the_key_option(cli):
    err = cli.fail("provider", "set", "h", "--key", "sk-secret-value")
    assert "sk-secret-value" not in err
    assert err.startswith("shunt: --key must be keyring, plaintext, none or env:<VARNAME>. Never pass a key value here")


def test_provider_list_prints_the_lines_and_flags_invalid_entries(cli):
    cli.set_providers({"version": 1, "providers": {"h": {**HTTP, "key": {"type": "env", "ref": "H_KEY"}}}})
    assert cli.ok("provider", "list") == "h\thttp\thttps://h.test/v1\tenv:H_KEY\n"
    cli.set_providers({"version": 1, "providers": {"h": {**HTTP, "key": {"type": "env", "ref": "H_KEY"}},
                                                    "bad": {"transport": "ftp"}}})
    assert cli.run("provider", "list") == 1
    assert "invalid: " in cli.out and cli.out.startswith("h\thttp\t")
    assert cli.err == (f"shunt: {cli.providers} has invalid entries (marked above). "
                       "Fix them before using those providers.\n")


def test_provider_list_without_providers(cli):
    none = f"shunt: no providers configured in {cli.providers}.\n"
    assert cli.ok("provider", "list") == none
    cli.set_providers({"version": 1, "providers": {}})
    assert cli.ok("provider", "list") == none
    cli.providers.write_text("not json")
    assert cli.fail("provider", "list") == f'shunt: {cli.providers} is invalid JSON or has no "providers" object.\n'


def test_provider_needs_set_or_list(cli):
    assert cli.fail("provider") == "shunt: usage: shunt-models provider <set|list> [args...]\n"
    assert cli.fail("provider", "drop") == "shunt: usage: shunt-models provider <set|list> [args...]\n"


# ---------------------------------------------------------------- key

def stdin_key(monkeypatch, text):
    import io
    monkeypatch.setattr("sys.stdin", io.TextIOWrapper(io.BytesIO(text.encode())))


def test_key_set_stores_a_plaintext_key_and_warns(cli, monkeypatch):
    cli.set_providers({"version": 1, "providers": {"p": {**HTTP, "key": {"type": "plaintext"}}}})
    stdin_key(monkeypatch, "sk-line\nsecond\n")
    out = cli.ok("key", "set", "p")
    assert out == "shunt: key stored for 'p' (type plaintext).\n"
    assert cli.err == (f"shunt: warning: the key is stored in plain text in {cli.providers} (mode 600). "
                       "Prefer a keyring or an environment variable.\n")
    assert json.loads(cli.providers.read_text())["providers"]["p"]["key"] == {"type": "plaintext", "ref": "sk-line"}
    assert (cli.providers.stat().st_mode & 0o777) == 0o600


def test_key_set_refuses_env_none_and_empty_keys(cli, monkeypatch):
    cli.set_providers({"version": 1, "providers": {
        "e": {**HTTP, "key": {"type": "env", "ref": "E_KEY"}}, "n": {**HTTP, "key": {"type": "none"}},
        "p": {**HTTP, "key": {"type": "plaintext"}}}})
    assert cli.fail("key", "set", "e") == ("shunt: provider 'e' uses an env key: export the variable named in its "
                                           "key.ref instead.\n")
    assert cli.fail("key", "set", "n") == "shunt: provider 'n' has key type none, there is no key to set.\n"
    stdin_key(monkeypatch, "")
    assert cli.fail("key", "set", "p") == "shunt: empty key, nothing stored.\n"
    assert "ref" not in json.loads(cli.providers.read_text())["providers"]["p"]["key"]


def test_key_set_for_a_keyring_provider_needs_a_backend(cli, monkeypatch):
    cli.set_providers({"version": 1, "providers": {"k": {**HTTP, "key": {"type": "keyring"}}}})
    monkeypatch.setattr("shunt.providers.keyring_backend", lambda _version_file: "")
    stdin_key(monkeypatch, "sk-x\n")
    assert cli.fail("key", "set", "k") == ("shunt: no keyring backend found (secret-tool, security, kwallet-query). "
                                          "Use an env key type instead.\n")


def test_key_set_hands_the_key_to_the_keyring_backend(cli, monkeypatch):
    cli.set_providers({"version": 1, "providers": {"k": {**HTTP, "key": {"type": "keyring"}}}})
    monkeypatch.setattr("shunt.providers.keyring_backend", lambda _version_file: "secret-tool")
    stored = []
    monkeypatch.setattr("shunt.providers.keyring_store",
                        lambda provider, _version_file, stdin: stored.append((provider, stdin.read())))
    stdin_key(monkeypatch, "sk-keyring\n")
    assert cli.ok("key", "set", "k") == "shunt: key stored for 'k' (type keyring).\n"
    assert stored == [("k", b"sk-keyring\n")] and cli.err == ""


def test_key_set_reads_the_terminal_without_echo(cli, monkeypatch):
    cli.set_providers({"version": 1, "providers": {"p": {**HTTP, "key": {"type": "plaintext"}}}})

    class Tty:
        def isatty(self):
            return True
    monkeypatch.setattr("sys.stdin", Tty())
    prompts = []
    monkeypatch.setattr("getpass.getpass", lambda prompt: prompts.append(prompt) or "sk-tty")
    cli.ok("key", "set", "p")
    assert prompts == ["API key (input hidden): "]
    assert json.loads(cli.providers.read_text())["providers"]["p"]["key"]["ref"] == "sk-tty"


def test_key_set_racing_a_provider_set_to_env_never_stores_the_key(cli, monkeypatch):
    key = "abcDEF0123456789abcdef0123456789"
    cli.set_providers({"version": 1, "providers": {"p": {**HTTP, "key": {"type": "plaintext"}}}})
    waiting, original = threading.Event(), providers_write._lock

    def spy(path, environ):
        waiting.set()
        return original(path, environ)
    monkeypatch.setattr(providers_write, "_lock", spy)
    monkeypatch.setenv("SHUNT_PROVIDERS_LOCK_TIMEOUT", "30")
    stdin_key(monkeypatch, key + "\n")
    result = []
    with file_lock(str(cli.providers), 5):
        worker = threading.Thread(target=lambda: result.append(models_cli.main(["key", "set", "p"])))
        worker.start()
        assert waiting.wait(10)
        cli.set_providers({"version": 1, "providers": {"p": {**HTTP, "key": {"type": "env", "ref": "P_API_KEY"}}}})
    worker.join(30)
    assert result == [1]
    assert key not in cli.providers.read_text()


def test_key_status_says_whether_a_key_resolves(cli, monkeypatch):
    cli.set_providers({"version": 1, "providers": {
        "e": {**HTTP, "key": {"type": "env", "ref": "E_KEY"}}, "n": {**HTTP, "key": {"type": "none"}},
        "p": {**HTTP, "key": {"type": "plaintext", "ref": "sk-x"}}}})
    monkeypatch.delenv("E_KEY", raising=False)
    assert cli.ok("key", "status", "e") == "shunt: provider 'e': no (type env)\n"
    monkeypatch.setenv("E_KEY", "value")
    assert cli.ok("key", "status", "e") == "shunt: provider 'e': yes (type env)\n"
    assert cli.ok("key", "status", "n") == "shunt: provider 'n': yes (type none, no key needed)\n"
    assert cli.ok("key", "status", "p") == "shunt: provider 'p': yes (type plaintext)\n"
    assert "sk-x" not in cli.out


def test_key_refusals(cli):
    cli.set_providers({"version": 1, "providers": {"p": {**HTTP, "key": {"type": "plaintext"}}}})
    assert cli.fail("key", "set") == "shunt: usage: shunt-models key <set|status> <provider>\n"
    assert cli.fail("key", "set", "q") == f"shunt: provider 'q' is not in {cli.providers}.\n"
    assert cli.fail("key", "bogus", "p") == "shunt: usage: shunt-models key <set|status> <provider>\n"
    for action in ("set", "status"):
        err = cli.fail("key", action, "a;rm -rf x")
        assert err == "shunt: invalid provider name (use letters, digits, dot, dash, underscore).\n"


def test_key_refuses_a_rejected_name_that_exists_in_providers_json(cli):
    cli.set_providers({"version": 1, "providers": {"_old": {**HTTP, "key": {"type": "plaintext"}}}})
    for action in ("set", "status"):
        err = cli.fail("key", action, "_old")
        assert '"_old"' in err and "edit providers.json" in err


def test_key_needs_the_providers_file(cli):
    assert cli.fail("key", "status", "p") == f"shunt: provider 'p' is not in {cli.providers}.\n"


# ---------------------------------------------------------------- dashboard, migrate, entry

def test_dashboard_takes_no_arguments_and_prints_the_report(cli, capsys):
    assert cli.fail("dashboard", "x") == "shunt: usage: shunt-models dashboard\n"
    out = cli.ok("dashboard")
    assert out.splitlines()[-1].startswith("setup")


def test_migrate_runs_with_this_script_as_the_hint(cli, monkeypatch):
    seen = {}

    def fake_run(args):
        seen["argv"], seen["hint"] = args.args, models_cli.os.environ["SHUNT_MODELS_HINT_CMD"]
        return 7
    monkeypatch.setattr("shunt.migrate.run", fake_run)
    assert cli.run("--migrate-from-opencode", "--apply", "--yes") == 7
    assert seen["argv"] == ["--apply", "--yes"]
    assert seen["hint"] == str(REPO_ROOT / "scripts" / "shunt-models")


def test_migrate_without_a_registry_reports_it(cli):
    assert cli.fail("--migrate-from-opencode") == f"shunt: no models registry at {cli.models}.\n"


def test_no_subcommand_and_an_unknown_subcommand(cli):
    assert cli.fail().startswith("shunt: usage: shunt-models <list|status|dashboard|add|remove|")
    assert cli.fail("") .startswith("shunt: usage: shunt-models")
    assert cli.fail("bogus") == "shunt: unknown subcommand: bogus\n"


def test_the_command_is_dispatched_before_argparse_with_raw_arguments(cli):
    from shunt.cli import main
    assert main(["shunt-models", "--", "bogus"]) == 1
    assert cli.capsys.readouterr().err == "shunt: unknown subcommand: bogus\n"
    cli.add("p/one")
    assert main(["shunt-models", "--", "request-body", "p/one", "--clear"]) == 0


def test_a_corrupt_registry_reads_as_an_explained_legacy_mode(cli):
    cli.models.write_text("{")
    assert cli.ok("list").startswith("shunt: models registry at ")
    assert "is not a valid models registry" in cli.fail("roles", "p/x", "bulk-read")


# ---------------------------------------------------------------- thinking --role

def _thinking_model(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "on", '{"reasoningEffort":"high"}')
    cli.ok("thinking", "p/m", "off", '{"reasoningEffort":"none"}')


def test_thinking_role_sets_only_that_role_and_rerenders_the_agent_files(cli):
    _thinking_model(cli)
    out = cli.ok("thinking", "p/m", "on", "--role", "code-write")
    assert out == "shunt: thinking for 'p/m' (role code-write) set to on.\n"
    entry = cli.entry()
    assert entry["role_thinking"] == {"code-write": True} and entry["thinking"] is False
    assert entry["thinking_off_options"] == {"reasoningEffort": "none"}
    assert "reasoningEffort: none" in cli.agent_text("shunt-bulk-reader-p-m")
    assert "reasoningEffort: none" not in cli.agent_text("shunt-code-writer-p-m")


def test_thinking_role_stores_options_given_with_it_for_the_matching_state(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "on", "--role", "code-write", '{"reasoningEffort":"high"}')
    assert cli.entry()["role_thinking"] == {"code-write": True}
    assert cli.entry()["thinking_options"] == {"reasoningEffort": "high"}
    assert "reasoningEffort: high" in cli.agent_text("shunt-code-writer-p-m")


def test_thinking_role_clear_removes_the_key_and_drops_the_empty_field(cli):
    _thinking_model(cli)
    cli.ok("thinking", "p/m", "on", "--role", "code-write")
    cli.ok("thinking", "p/m", "off", "--role", "bulk-read")
    assert cli.entry()["role_thinking"] == {"code-write": True, "bulk-read": False}
    out = cli.ok("thinking", "p/m", "--role", "bulk-read", "--clear")
    assert out == "shunt: thinking for 'p/m' (role bulk-read) cleared.\n"
    assert cli.entry()["role_thinking"] == {"code-write": True}
    cli.ok("thinking", "p/m", "--role", "code-write", "--clear")
    assert "role_thinking" not in cli.entry()
    assert "reasoningEffort: none" in cli.agent_text("shunt-code-writer-p-m")


def test_thinking_without_role_leaves_role_thinking_alone(cli):
    cli.add("p/m")
    cli.ok("thinking", "p/m", "on", "--role", "code-write")
    cli.ok("thinking", "p/m", "on", '{"reasoningEffort":"high"}')
    cli.ok("thinking", "p/m", "off")
    assert cli.entry()["role_thinking"] == {"code-write": True} and cli.entry()["thinking"] is False


@pytest.mark.parametrize("args,message", [
    (("p/m", "on", "--role", "thinker"), "shunt: unknown role 'thinker' (roles: bulk-read code-write).\n"),
    (("p/m", "on", "--role"), USAGE_THINKING),
    (("p/m", "--clear"), USAGE_THINKING),
    (("p/m", "--role", "bulk-read"), USAGE_THINKING),
    (("p/m", "on", "--role", "bulk-read", "--clear"), USAGE_THINKING),
    (("p/m", "bogus", "--role", "bulk-read"), "shunt: thinking state must be 'on' or 'off'.\n"),
])
def test_thinking_role_refusals_change_nothing(cli, args, message):
    cli.add("p/m")
    before = cli.models.read_text()
    assert cli.fail("thinking", *args) == message
    assert cli.models.read_text() == before


def test_add_of_an_id_with_a_control_character_leaves_the_registry_untouched(cli):
    cli.opencode("p")
    code = cli.run("add", "p/a\nb")
    assert code != 0
    assert not cli.models.exists() or cli.doc()["models"] == []


@pytest.mark.parametrize("model_id", ["p/a b", "p/é", "p/a\tb", "p/a\x7fb"])
def test_add_of_an_odd_id_either_succeeds_with_an_agent_file_or_leaves_no_entry(cli, model_id):
    cli.opencode("p")
    code = cli.run("add", model_id)
    entries = cli.doc()["models"] if cli.models.exists() else []
    if code != 0:
        assert entries == []
    else:
        assert (cli.agents / f"{entries[0]['agent']}.md").is_file()



# ---------------------------------------------------------------- adversarial probes

@pytest.mark.parametrize("sep", [" ", " ", "\u0085", "\x7f", "\x1b", "\r"])
def test_add_refuses_a_line_break_or_control_char_in_the_id(cli, sep):
    cli.opencode("p")
    err = cli.fail("add", f"p/a{sep}b")
    assert "control character" in err
    assert not cli.models.exists() or cli.doc()["models"] == []
    assert not cli.agents.exists() or not list(cli.agents.iterdir())


def test_add_with_a_unicode_line_separator_does_not_reach_the_agent_file(cli):
    cli.opencode("p")
    code = cli.run("add", "p/a name: evil")
    for agent in (cli.agents.iterdir() if cli.agents.exists() else []):
        assert " " not in agent.read_text()
    assert code != 0


@pytest.mark.parametrize("model_id", ["p/-x", "p/a b", "p/a/b", "p/ä", "p/" + "x" * 5000])
def test_adv_add_accepts_odd_but_printable_ids_and_writes_matching_agent_files(cli, model_id):
    cli.opencode("p")
    code = cli.run("add", model_id)
    if code == 0:
        assert cli.entry()["id"] == model_id
        assert (cli.agents / f"{cli.entry()['agent']}.md").is_file()
