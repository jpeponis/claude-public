# User-level instructions

Deployed to `~/.claude/CLAUDE.md`, so Claude reads this wherever a session starts. Desktop-scoped
notes live in `{{DESKTOP}}/CLAUDE.md`; how the config is synced is in `{{CONFIG_ROOT}}/README.md`.

## Agent usage
- Delegate bulk or multi-file operations (organize, mass move/copy/rename/delete) to the file-manager agent. Trivial single-file operations may be done inline.
- Before dispatching any file-manager task, verify the destination path exists (a one-second `ls` beats a 45-second agent round-trip that bounces back with a question).

## Config layout
- Settings, skills, agents and shell functions live under `$env:USERPROFILE\.claude\`, deployed there from `{{CONFIG_ROOT}}`. **Edit the repo, then `/sync-config push`** — editing the deployed copy works until the next deploy overwrites it.
- Skills are directories: `.claude/skills/<name>/SKILL.md`, where the directory name is the slash command. A skill's `description` frontmatter is what Claude reads to decide whether to use it; without one it sees only the first paragraph.
- Secrets are DPAPI-encrypted per machine at `.claude/.<name>.enc` and never sync. Read them only through `{{CONFIG_ROOT}}/Get-Secret.ps1`, so there is one decrypt path rather than a private copy in each caller.

## Billing modes
- **Default (subscription)**: no `ANTHROPIC_API_KEY` set, 200K context.
- **API mode**: pay-as-you-go, and the only way to get the 1M context window (`--model <name>[1m]`).
- Shell functions `claude-api`, `claude-api-sp`, `claude-api-spsp` set the key from the encrypted store and clear it on exit. `{{CONFIG_ROOT}}/claude-api.ps1` is the standalone equivalent (`-Extended`, `-SP`, `-SPSP`).
- In-session, the `/api-agent` skill shells a single prompt out to a separate API-billed process.
- `claude-sp` **replaces** the default system prompt (`--system-prompt-file`); `claude-api-sp` **appends** to it (`--append-system-prompt-file`). The asymmetry is deliberate.

## MCP
- Tool Search is on via the `ENABLE_TOOL_SEARCH=true` User env var, which `deploy.ps1` sets, so MCP tool definitions load lazily and cost no context until used.
- `/mcp` toggles servers in-session without restarting; `@` browses MCP resources; `claude mcp list` shows what is connected. Add servers with `claude mcp add --transport http <name> <url>`, run outside a session.
- Subagents inherit the parent session's MCP tools. Background subagents cannot use them at all.

## Windows notes
- **Never** pass PowerShell containing `$variables`, `$null` or nested quotes inline via `powershell.exe -Command "..."` from bash — both shells fight over `$`. Write a temp `.ps1`, run it with `-ExecutionPolicy Bypass -File`, delete it. Inline `-Command` is fine only when there is no `$`.
- Resolve Desktop and Documents with `[Environment]::GetFolderPath(...)`, never `$env:USERPROFILE\Desktop`. OneDrive Known Folder Move redirects both, and the literal path is then either missing or a stale leftover.
- **claude-in-chrome**: if its tools report "not connected", run `/mcp` — it reconnects in-session. Don't retry more than twice. The fallback that works is `playwright-core` driving the installed Chrome (`chromium.launch({ channel: 'chrome' })`), which downloads no browser.
- Stop background dev servers (`python -m http.server` and friends) when the work phase ends rather than leaving them running.
