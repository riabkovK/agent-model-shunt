load 'test_helper'

# frontmatter_model <skill>: the model: line of a skill's YAML frontmatter.
frontmatter_model() {
  awk 'NR == 1 { next } /^---$/ { exit } /^model:/ { sub(/^model:[ \t]*/, ""); print }' \
    "$REPO_ROOT/skills/$1/SKILL.md"
}

@test "management skills are pinned to haiku" {
  local s
  for s in model-config usage-report toggle-debug-log toggle-hooks; do
    [ "$(frontmatter_model "$s")" = "haiku" ] || { echo "$s is not pinned to haiku"; return 1; }
  done
}

@test "delegation skills are not pinned to a model" {
  local s
  for s in bulk-reader code-writer; do
    [ -z "$(frontmatter_model "$s")" ] || { echo "$s pins a model"; return 1; }
  done
}

# unprefixed_script_refs <skill-md>: body lines naming a plugin script without
# the plugin root, which fails when the session runs in another project.
unprefixed_script_refs() {
  awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$1" |
    grep -E '(^|[^/])scripts/[a-z]' | grep -v 'scripts/lib/' |
    grep -vE '^The plugin root is'
}

@test "skills name plugin scripts through CLAUDE_PLUGIN_ROOT" {
  local f bad=""
  for f in "$REPO_ROOT"/skills/*/SKILL.md; do
    if unprefixed_script_refs "$f" >/dev/null; then bad="$bad $f"; fi
  done
  [ -z "$bad" ] || { echo "unprefixed script paths in:$bad"; return 1; }
}

@test "model-config SKILL.md offers the healthcheck flag" {
  run grep -c -- '--healthcheck' "$REPO_ROOT/skills/model-config/SKILL.md"
  assert_success
}
