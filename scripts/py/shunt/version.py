"""Plugin version, read from .claude-plugin/plugin.json (the single source)."""

import json
from pathlib import Path

PLUGIN_JSON = Path(__file__).resolve().parents[3] / ".claude-plugin" / "plugin.json"


def plugin_version(path: Path = PLUGIN_JSON) -> str:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)["version"]
