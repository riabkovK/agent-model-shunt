# Project Rules: agent-model-shunt

Project-specific rules. These extend the global ECC rules in `~/.claude/rules/`
and take precedence over them where more specific.

## Branching

- One feature branch per **Phase**, not one branch for the whole project. `main` is protected;
  merge via PR even when reviewing your own work.
- Do not start a new phase's branch until the current phase's branch is merged.

## Commits

- One commit per sub-phase (or other clearly separable unit of work), not one giant
  commit per phase and not an uncommitted pile of sub-phases.
- Message format: `<type>: <description>` — single line only, no multi-line body.
  Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.
- Never add a `Co-Authored-By` line or any other attribution line to commit messages.
- Still only commit on explicit user request (see global `git-workflow.md`) — these
  rules govern how to shape commits once asked for, not when to make them.

## Pull Requests

- Always write the PR title and description in English, regardless of the
  language the conversation is in.

## Context Management

- Do not let the main session's context fill past roughly 25%. When continuing the
  current unit of work would push past that threshold, package the next
  self-contained piece of work (e.g. one sub-phase's TDD + review pass) as a task
  for a lightweight subagent with a clean context, launch it, and tell the user it
  is a good time to run `/compact` on the main session.
- After the user compacts, fetch the subagent's result and continue from it instead
  of re-deriving the work in the main session.\