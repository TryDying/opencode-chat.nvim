# Repository Engineering Rules

## Repository summary

- This repository contains the `opencode-chat.nvim` Neovim plugin.
- The Lua module name is `opencode_chat`.
- The first milestone is an MVP based on native Neovim terminal/floating windows plus opencode's local HTTP bridge, not a full native chat UI.
- Project-facing documentation under `docs/` and the lessons log `PROGRESS.md` are maintained in Chinese.

## Documentation index

- `docs/01-项目指南.md`: project purpose, MVP scope, and reader-facing directory map.
- `docs/02-开发指南.md`: setup, local workflow, commands, and validation guidance.
- `docs/03-技术指南.md`: architecture, module responsibilities, data flow, and implementation constraints.
- `docs/04-更新日志.md`: release-style project changelog.
- `PROGRESS.md`: sparse Chinese lessons-learned log for important bug fixes or significant changes only.

## Documentation semantics

- `AGENTS.md` is the repository operation layer: workflow rules, commands, implementation constraints, subagent routing, and maintenance rules live here.
- `docs/` is the project explanation layer: project background, usage/development narrative, architecture narrative, and reader-oriented detail live there.
- `PROGRESS.md` is the historical lessons layer: record only high-signal learnings from important bugs or significant changes.
- Do not duplicate repository policy, agent instructions, or documentation maintenance rules into `docs/` or `PROGRESS.md`.

## Subagent Routing

These routing rules are mandatory for this repository.

- Delegate broad local code browsing, symbol lookup, implementation tracing, and repository-context gathering to the `code-explorer` subagent when CodeGraph/direct reads are not enough.
- Delegate external documentation, official references, release notes, best practices, and web research to the `web-researcher` subagent.
- Delegate build, run, lint, test, benchmark, and other log-heavy validation commands to the `runner` subagent.
- The main agent owns task decomposition, decisions, implementation, file edits, integration, and final delivery.

## Common commands

- Run the self-contained Neovim test suite without loading global user config: `nvim --clean -u NONE --headless -l tests/run.lua`.
- The test suite uses `tests/fixtures/opencode` as a fake opencode HTTP bridge; it does not require a real opencode server.
- Expected future focused checks for Lua code should prefer fast local validation first, such as `luacheck`/`stylua` only after those tools are added to the repo.
- Do not invent package-manager, test, lint, or build commands until the relevant manifests/configs exist.

## Architecture highlights

- Use only native Neovim terminal/floating window APIs for the MVP; do not add `vim-floaterm` support.
- Treat the terminal as a display container only. Neovim-to-opencode communication must use local HTTP.
- MVP integration is `opencode --port <port>` plus `POST /tui/append-prompt`; do not inject text with `chansend()`.
- Repeated toggles in one Neovim process must reuse the same opencode TUI/session. Restarting Neovim should create a new session.
- Visual-mode context append must not submit the prompt; it must leave text in the opencode input box for the user to continue editing.
- File references should use `@relative/path`; selection references should use `@relative/path#Lstart-Lend` with ascending line numbers.
- Project root markers are `.root`, `.git`, `.svn`, `.hg`, `.project`, `.ccls`.

## Planned module boundaries

- `lua/opencode_chat/config.lua`: defaults and user configuration merge.
- `lua/opencode_chat/root.lua`: project root detection from root markers.
- `lua/opencode_chat/terminal.lua`: native floating terminal, terminal buffer, and opencode job lifecycle.
- `lua/opencode_chat/client.lua`: HTTP wrapper for `/tui/append-prompt`.
- `lua/opencode_chat/context.lua`: current-file and Visual-selection reference generation.
- `lua/opencode_chat/commands.lua`: command registration such as `:OpencodeToggle`.
- `lua/opencode_chat/init.lua`: public setup/API entrypoint.

## Explicit non-goals for the MVP

- Do not implement `opencode serve` plus a native Neovim chat UI yet.
- Do not implement diff apply, file tree, multi-session picker, prompt templates, or agent/mode management yet.
- Do not add a floaterm backend.

## Validation focus

- Manually verify that `POST /tui/append-prompt` appends text without pressing Enter/submitting.
- Manually verify that hide/show toggle does not create a new opencode session in the same Neovim process.
- Manually verify that reversed Visual selections still produce ascending line ranges.

## Documentation maintenance rules

- Keep `AGENTS.md` in English.
- Keep `docs/` and `PROGRESS.md` in Chinese.
- Keep repository policy, task workflow, subagent routing, and maintenance rules in `AGENTS.md`.
- Keep project-facing explanations in `docs/`; link instead of duplicating long explanations across files.
- Keep `docs/04-更新日志.md` release-style and project-facing; changelog maintenance rules belong here in `AGENTS.md`.

## Task Completion Protocol

- Default finish state for a logical unit of work:
  1. validate the relevant changes with the narrowest useful checks;
  2. create the main checkpoint commit for code/config/test changes when allowed;
  3. decide whether the change qualifies for `PROGRESS.md` by default;
  4. if qualified, append `PROGRESS.md` with the main commitID and create a separate sidecar commit containing only `PROGRESS.md`.
- The main code/config/test checkpoint commit is the source of truth for the `commitID` recorded in `PROGRESS.md`.
- Allowed stop conditions: unsafe git state, explicit user instruction not to commit, current branch is `main`/`master`, validation failure not accepted by the user, or work has not reached a logical completion point.
- Do not commit on `main`/`master` unless the user explicitly asks.

## PROGRESS.md Rules

- `PROGRESS.md` is a sparse, append-only Chinese log for high-signal lessons learned, not a routine work log.
- Only append entries after important bug fixes or significant changes.
- Never record project initialization, scaffolding generation, documentation-only updates, formatting-only changes, routine configuration tweaks, or other low-signal work.
- Each real entry must be concise and include: problem, solution, prevention, and commitID.
- Qualify changes for `PROGRESS.md` when they fix an important bug, change a key workflow or invariant, alter a critical entrypoint/regression path, or capture a lesson likely to prevent repeated mistakes.
- Record the main code/config/test checkpoint commitID, not the follow-up sidecar commitID.
