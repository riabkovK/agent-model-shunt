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
