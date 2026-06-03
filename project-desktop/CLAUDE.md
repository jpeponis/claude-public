## Agent Usage
- Delegate all file/folder operations (move, copy, delete, rename, organize) to the file-manager agent.

## Claude Code File Locations
- **Global settings**: `C:\Users\{{USERNAME}}\.claude\settings.json`
- **Project-local settings**: `C:\Users\{{USERNAME}}\Desktop\.claude\settings.local.json`
- **Skills (slash commands)**: `C:\Users\{{USERNAME}}\.claude\commands\` (Markdown files, e.g., `sync-config.md`)
- **Agent definitions**: `C:\Users\{{USERNAME}}\.claude\agents\` (Markdown files, e.g., `file-manager.md`)
- **Project instructions**: `C:\Users\{{USERNAME}}\Desktop\CLAUDE.md` (this file)
- **Encrypted API key**: `C:\Users\{{USERNAME}}\.claude\.api-key.enc` (DPAPI-encrypted, same-user-only)

## Billing Modes
- **Default (subscription)**: Pro plan. No `ANTHROPIC_API_KEY` set. 200K context limit.
- **API mode**: Pay-as-you-go. Enables 1M token context via `--model modelname[1m]`.
- **Toggle mechanism**: PowerShell functions `claude-api`, `claude-api-sp`, `claude-api-spsp` set the API key from the encrypted store and clean it up on exit.
- **Standalone script**: `Desktop\claude-config\claude-api.ps1` launches a full API-mode session with `-Extended`, `-SP`, `-SPSP` flags.
- **System prompt**: `Desktop\claude-config\System Prompt.txt` — referenced by all `-sp`/`-spsp` variants.

## MCP Server Management
- **MCP Tool Search** is always on (`ENABLE_TOOL_SEARCH=true` user env var). Lazy-loads MCP tool definitions to save context.
- Use `/mcp` in-session to toggle servers on/off without restarting.
- Use `@` to browse available MCP resources in the prompt.
- Run `claude mcp list` to see currently connected servers. Their tool definitions are lazy-loaded via Tool Search, so they don't consume active context until used.
- Subagents inherit the parent session's MCP tools. Background subagents cannot use MCP tools.
- To add new servers: `claude mcp add --transport http <name> <url>` (run outside Claude Code session).

## Bash ↔ PowerShell Escaping
- Never pass complex PowerShell (containing `$variables`, `$null`, nested quotes) inline via `powershell.exe -Command "..."` from bash. Both shells fight over `$`.
- Instead: write a temp `.ps1` file, run with `powershell.exe -ExecutionPolicy Bypass -File <path>`, then delete it.
- Inline `-Command` is fine only for trivial commands with no `$` symbols.
