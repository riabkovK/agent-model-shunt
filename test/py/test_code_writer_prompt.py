"""Content checks of the code-writer role prompt (prompts/code-writer.md).

`models materialize` copies the prompt verbatim as the agent body (see test_models.py), so the
protocol the parser in code_write relies on is guarded here, against the real file.
"""

import re
from pathlib import Path

PROMPT = (Path(__file__).resolve().parents[2] / "prompts" / "code-writer.md").read_text()
TAG_LINE = re.compile(r"^</?SHUNT-(NOTES|CODE)>$")
PROTOCOL_ORDER = ["<SHUNT-NOTES>", "</SHUNT-NOTES>", "<SHUNT-CODE>", "</SHUNT-CODE>"]


def _tag_lines(text):
    return [line for line in text.splitlines() if TAG_LINE.match(line)]


def test_prompt_describes_the_response_protocol():
    lowered = PROMPT.lower()
    for tag in PROTOCOL_ORDER:
        assert tag in _tag_lines(PROMPT)
    for phrase in ("exactly one", "only symbols", "not wrap"):
        assert phrase in lowered
    assert "four backticks" in PROMPT


def test_prompt_says_each_tag_appears_once_and_is_never_quoted():
    assert "exactly once in the whole reply" in PROMPT
    assert "never quoted" in PROMPT


def test_prompt_lists_the_four_tags_in_order_and_never_tells_the_model_to_omit_the_closing_tag():
    assert _tag_lines(PROMPT)[:4] == PROTOCOL_ORDER
    assert "nothing but blank lines" in PROMPT.lower()
    assert "no closing" not in PROMPT.lower()
    assert "<<<" not in PROMPT


def test_prompt_carries_a_full_example_reply():
    match = re.search(r"^Example of a complete, correct reply.*?^End of example\.$", PROMPT, re.M | re.S)
    assert match, "the example block is missing"
    example = match.group(0)
    assert _tag_lines(example) == PROTOCOL_ORDER
    assert "\ndef add(a, b):\n" in example
