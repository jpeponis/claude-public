# Sync Claude Code Configuration

Keeps Claude Code settings, skills, agents, and shell profile in sync across machines via a private GitHub repo (`~/Desktop/claude-config`).

## Usage
/sync-config [push|pull]

## What gets synced
Settings, skills (`commands/*.md`), agents (`agents/*.md`), workflows (`.claude/workflows/*.js`), project CLAUDE.md, statusline script, and the shell functions file.

**Not** the PowerShell profile: deploy adds a small managed block to each profile that dot-sources `~/.claude/claude-functions.ps1`, and never rewrites anything else in it. Sensitive files (API keys, OAuth tokens) are excluded — they are DPAPI-encrypted per machine. Username is parameterized (`{{USERNAME}}`) so the repo is machine-portable.

## Behavior

The script is `sync-config.ps1` in the config repo. Always quote `"$HOME/..."` in bash so the variable expands. Do NOT use `$env:USERPROFILE`.

### Pull (default)
Run:
```
powershell.exe -ExecutionPolicy Bypass -File "$HOME/Desktop/claude-config/sync-config.ps1" pull
```
Report output to the user. Remind them to restart Claude Code if settings changed.

### Push
1. Run with `-DryRun` first:
```
powershell.exe -ExecutionPolicy Bypass -File "$HOME/Desktop/claude-config/sync-config.ps1" push -DryRun
```
2. Show the user what will be committed and **ask for confirmation**.
3. If confirmed, run without `-DryRun`:
```
powershell.exe -ExecutionPolicy Bypass -File "$HOME/Desktop/claude-config/sync-config.ps1" push
```

### Default
If no argument is provided, default to **pull**.

## Troubleshooting
- **git push/pull auth fails**: Git credential manager handles auth. Run `git -C "$HOME/Desktop/claude-config" push origin main` manually to diagnose. On a new machine the repo must be cloned first — see the README for the clone URL and first-time setup. (Do not reconstruct the URL from `{{USERNAME}}`: that placeholder is the *Windows* account name, not the GitHub account.)
- **"Nothing to commit"**: Local config already matches the repo. This is normal.
- **Merge conflicts after push pull**: Resolve manually in the repo directory, then retry.
- **Missing API key warning on pull**: Expected on a new machine. Encrypt your Anthropic key with DPAPI locally — it can't be synced.
- **Missing GITHUB_PERSONAL_ACCESS_TOKEN warning**: Only needed for the GitHub MCP server, not for git push/pull.
- **Deploy overwrites local edits**: The deploy script backs up existing files to `.backups/<timestamp>/` before overwriting. Check there to recover.
