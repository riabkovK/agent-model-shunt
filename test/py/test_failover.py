"""The failover loop (failover.py) and the transport dispatch (transport.py), in process.

HTTP candidates go to the scripted local server. An OpenCode candidate runs a fake `opencode`
executable written into tmp_path.
"""

import json
import os
import stat

import pytest

from shunt import failover, transport
from shunt import transport_reply as reply

KEY = "sk-failover-secret-key-789"
ROUTE = "/v1/chat/completions"
BAD_ROUTE = "/bad/v1/chat/completions"
OK = {"choices": [{"message": {"content": "hello"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 4, "completion_tokens": 2}}
TRANSCRIPT = ('{"type":"text","part":{"text":"from cli"}}\n'
              '{"type":"step_finish","part":{"reason":"stop","cost":0.5,"tokens":{"input":3,"output":1}}}\n')


@pytest.fixture
def fo(tmp_path, http_server):
    """Models acme/m1 (good http), bad/m2 (http, 500), cli/m3 (opencode) and a recording fake opencode."""
    prompts = tmp_path / "prompts"
    prompts.mkdir()
    (prompts / "bulk-reader.md").write_text("You read.\n")
    (prompts / "code-writer.md").write_text("You write.\n")
    http_server.script(ROUTE, body=OK)
    http_server.script(BAD_ROUTE, status=500, body={"error": "boom"})

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "opencode"
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >"$FAKE_ARGS"\nenv >"$FAKE_ENV"\ncat <<\'EOT\'\n'
                    + TRANSCRIPT + "EOT\n")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    class Fo:
        server = http_server
        path = tmp_path
        args = tmp_path / "args.txt"
        child_env = tmp_path / "child-env.txt"
        environ = {**os.environ, "SHUNT_MODELS_FILE": str(tmp_path / "models.json"),
                   "SHUNT_PROVIDERS_FILE": str(tmp_path / "providers.json"),
                   "SHUNT_PROMPTS_DIR": str(prompts), "SHUNT_AGENTS_DIR": str(tmp_path / "agents"),
                   "SHUNT_OPENCODE_CONFIG_HOME": str(tmp_path / "ocfg"),
                   "SHUNT_ISOLATED_CONFIG_DIR": str(tmp_path / "iso"),
                   "SHUNT_OPENCODE_BIN": str(fake), "SHUNT_BREAKER_STATE_FILE": str(tmp_path / "breaker.json"),
                   "SHUNT_BREAKER_CONFIG_FILE": str(tmp_path / "breaker-config.json"),
                   "SHUNT_TIMEOUT_SECONDS": "5", "ACME_KEY": KEY, "FAKE_ARGS": str(tmp_path / "args.txt"),
                   "FAKE_ENV": str(tmp_path / "child-env.txt")}

        def registry(self, *models, active=None):
            doc = {"version": 1, "models": list(models)}
            if active:
                doc["active"] = active
            (tmp_path / "models.json").write_text(json.dumps(doc))

        def providers(self, **extra):
            base = http_server.url
            doc = {"acme": {"transport": "http", "base_url": base + "/v1", "key": {"type": "env", "ref": "ACME_KEY"}},
                   "bad": {"transport": "http", "base_url": base + "/bad/v1", "key": {"type": "env", "ref": "ACME_KEY"}},
                   "cli": {"transport": "opencode"}, **extra}
            (tmp_path / "providers.json").write_text(json.dumps({"version": 1, "providers": doc}))

        def cli_agent(self, name="shunt-bulk-reader-cli-m3"):
            (tmp_path / "agents").mkdir(exist_ok=True)
            (tmp_path / "agents" / f"{name}.md").write_text("---\nmodel: cli/m3\n---\nbody\n")

        def run(self, role="bulk-read", kind="bulk", question="q", files=(), **options):
            return failover.run_role(role, kind, question, list(files), self.environ, **options)

        def breaker(self):
            path = tmp_path / "breaker.json"
            return json.loads(path.read_text()).get("models", {}) if path.exists() else {}

    fixture = Fo()
    fixture.providers()
    return fixture


def model(model_id, **fields):
    return {"id": model_id, "enabled": True, **fields}


def reply_text(path):
    return json.loads(open(path).read())["text"]


def test_first_good_http_model_answers_and_the_breaker_records_success(fo):
    fo.registry(model("acme/m1"))
    found = fo.run()
    assert (found.model_id, found.index) == ("acme/m1", 0)
    assert reply_text(found.path) == "hello"
    assert fo.breaker()["acme/m1"]["failures"] == 0
    os.unlink(found.path)


def test_a_failing_model_gets_a_note_and_a_breaker_failure_and_the_next_one_answers(fo, capsys):
    fo.registry(model("bad/m2"), model("acme/m1"))
    found = fo.run()
    assert found.model_id == "acme/m1"
    assert "shunt: bad/m2 failed: HTTP request error" in capsys.readouterr().err
    assert fo.breaker()["bad/m2"]["failures"] == 1
    assert fo.breaker()["acme/m1"]["failures"] == 0


def test_the_code_write_role_keys_the_breaker_by_role_and_uses_the_writer_agent(fo):
    fo.registry(model("acme/m1"))
    found = fo.run(role="code-write", kind="writer")
    assert found.model_id == "acme/m1"
    assert "acme/m1#code-write" in fo.breaker()
    assert "acme/m1" not in fo.breaker()


def test_a_rejected_key_skips_the_model_without_a_breaker_failure(fo, capsys):
    fo.server.script(BAD_ROUTE, status=401, body={"error": "no"})
    fo.registry(model("bad/m2"), model("acme/m1"))
    assert fo.run().model_id == "acme/m1"
    assert "shunt: bad/m2 failed: auth failed" in capsys.readouterr().err
    assert "bad/m2" not in fo.breaker()


def test_a_config_problem_skips_the_model_without_a_breaker_failure(fo, capsys):
    fo.providers(bad={"transport": "http", "base_url": "ftp://x", "key": {"type": "none"}})
    fo.registry(model("bad/m2"), model("acme/m1"))
    assert fo.run().model_id == "acme/m1"
    assert "config problem (see above), skipped" in capsys.readouterr().err
    assert "bad/m2" not in fo.breaker()


def test_every_candidate_oversize_ends_with_the_read_it_yourself_message(fo, capsys):
    fo.registry(model("acme/m1", context_tokens=1000, oversize_policy="fail"))
    big = fo.path / "big.txt"
    big.write_text("x" * 5000)
    with pytest.raises(failover.Fatal) as info:
        fo.run(files=[str(big)])
    assert str(info.value) == ("no delegate model can take this input (1 refused it as too large, the others "
                               "failed or are paused). Read the file directly instead, in sections with offset/limit.")
    assert "input too large for this model" in capsys.readouterr().err
    assert fo.breaker() == {}


def test_an_open_breaker_skips_the_model_and_all_open_is_fatal(fo):
    fo.registry(model("acme/m1"))
    (fo.path / "breaker.json").write_text(json.dumps({"models": {"acme/m1": {"failures": 3, "cooldown_until": 2**40}}}))
    with pytest.raises(failover.Fatal, match="currently paused"):
        fo.run()


def test_no_candidate_with_the_role_is_fatal_with_a_role_specific_hint(fo):
    fo.registry(model("acme/m1", roles=["bulk-read"]))
    with pytest.raises(failover.Fatal, match=r"no enabled delegate models with the code-write role .*Add or enable"):
        fo.run(role="code-write", kind="writer")


def test_all_models_failing_is_fatal(fo):
    fo.registry(model("bad/m2"))
    with pytest.raises(failover.Fatal, match="all delegate models in the registry failed for this call."):
        fo.run()
    assert fo.breaker()["bad/m2"]["failures"] == 1


def test_an_active_model_missing_from_the_registry_is_warned_about_once_when_asked(fo, capsys):
    fo.registry(model("acme/m1"), active="ghost/x")
    fo.run(warn_active=True)
    assert capsys.readouterr().err.count("active model 'ghost/x' is not in the models list") == 1
    fo.run()
    assert "ghost/x" not in capsys.readouterr().err


def test_external_accept_returns_the_reply_without_a_breaker_record_and_resumes_after_it(fo):
    fo.registry(model("acme/m1"), model("acme/m2"))
    first = fo.run(external=True)
    assert (first.model_id, first.index, first.oversize) == ("acme/m1", 0, 0)
    assert fo.breaker() == {}
    second = fo.run(external=True, start=first.index + 1, oversize=4)
    assert (second.model_id, second.index, second.oversize) == ("acme/m2", 1, 4)


def test_resuming_past_the_last_candidate_is_not_reported_as_paused(fo):
    fo.registry(model("acme/m1"))
    with pytest.raises(failover.Fatal, match="all delegate models in the registry failed"):
        fo.run(external=True, start=1)


def test_an_opencode_model_runs_the_cli_with_an_explicit_argv_and_no_key(fo):
    fo.registry(model("cli/m3"))
    fo.cli_agent()
    attachment = fo.path / "-dash.txt"
    attachment.write_text("data\n")
    found = fo.run(question="what is it", files=["-dash.txt", str(attachment)])
    assert reply_text(found.path) == "from cli"
    argv = fo.args.read_text().split("\n")[:-1]
    assert argv[:5] == ["run", "--agent", "shunt-bulk-reader-cli-m3", "what is it", "-f"]
    assert argv[5] == "./-dash.txt"
    assert argv[-2:] == ["--format", "json"]
    assert KEY not in fo.args.read_text()
    child = dict(line.split("=", 1) for line in fo.child_env.read_text().splitlines() if "=" in line)
    assert child["XDG_CONFIG_HOME"] == str(fo.path / "iso" / "shunt-bulk-reader-cli-m3")
    assert "SHUNT_TRANSPORT" not in child
    assert fo.breaker()["cli/m3"]["failures"] == 0


def test_an_opencode_agent_that_is_missing_is_a_config_problem(fo, capsys):
    fo.registry(model("cli/m3"), model("acme/m1"))
    assert fo.run().model_id == "acme/m1"
    err = capsys.readouterr().err
    assert "OpenCode agent 'shunt-bulk-reader-cli-m3' not found" in err
    assert "cli/m3" not in fo.breaker()


def test_failure_reasons_name_the_transport_and_strip_control_characters(fo, capsys):
    fo.registry(model("bad/m2"), model("cli/m3"))
    failover.note_failure("a\x1b[31m/x", reply.EMPTY, "", fo.environ)
    failover.note_failure("cli/m3", reply.ERROR, "shunt-bulk-reader-cli-m3", fo.environ)
    failover.note_failure("bad/m2", reply.ERROR, "shunt-bulk-reader-bad-m2", fo.environ)
    failover.note_failure("x", reply.ERROR, "", fo.environ)
    failover.note_failure("x", reply.TIMEOUT, "", {**fo.environ, "SHUNT_TIMEOUT_SECONDS": "9"})
    failover.note_failure("x", reply.DEADLINE, "", fo.environ)
    failover.note_failure("x", 77, "", fo.environ)
    assert capsys.readouterr().err.splitlines() == [
        "shunt: a[31m/x failed: empty output",
        "shunt: cli/m3 failed: opencode error",
        "shunt: bad/m2 failed: HTTP request error",
        "shunt: x failed: request error",
        "shunt: x failed: timed out after 9s",
        "shunt: x failed: total deadline reached (SHUNT_TOTAL_TIMEOUT_SECONDS)",
        "shunt: x failed: unexpected status 77",
    ]


def test_legacy_invoke_without_a_registry_runs_the_agent_and_fails_with_a_message(fo, capsys):
    fo.cli_agent("bulk-reader")
    path = failover.invoke_legacy("bulk-reader", "q", [], fo.environ)
    assert reply_text(path) == "from cli"
    os.unlink(path)
    broken = {**fo.environ, "SHUNT_OPENCODE_BIN": "/nonexistent/opencode"}
    with pytest.raises(failover.Fatal, match=r"opencode run failed for agent 'bulk-reader' \(not found, timed out after 5s"):
        failover.invoke_legacy("bulk-reader", "q", [], broken)


def test_an_unknown_transport_and_an_invalid_providers_file_are_config_problems(fo, capsys):
    fo.registry(model("acme/m1"))
    status, _ = transport.invoke_status("shunt-bulk-reader-acme-m1", "q", [], {**fo.environ, "SHUNT_TRANSPORT": "bogus"})
    assert status == reply.CONFIG
    assert "unknown transport 'bogus' (supported: opencode, http)." in capsys.readouterr().err
    (fo.path / "providers.json").write_text("not json")
    status, _ = transport.invoke_status("shunt-bulk-reader-acme-m1", "q", [], fo.environ)
    err = capsys.readouterr().err
    assert status == reply.CONFIG
    assert "cannot work out the transport of agent 'shunt-bulk-reader-acme-m1': providers.json is unusable" in err


def test_the_key_never_reaches_stderr_when_a_model_fails_over(fo, capsys):
    fo.registry(model("bad/m2"), model("cli/m3"))
    fo.cli_agent()
    assert fo.run(files=[]).model_id == "cli/m3"
    assert KEY not in capsys.readouterr().err
