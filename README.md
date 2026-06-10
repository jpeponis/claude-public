# Claude Code Portable Configuration

A template for syncing Claude Code settings, agents, slash commands, and dynamic workflows across multiple Windows machines. This is the public version of a personal setup — feel free to fork, adapt, and add your own skills, agents, and workflows.

## Repository Structure

- `global/` — Maps to `%USERPROFILE%\.claude\` (global Claude Code config)
  - `settings.json` — Global settings and permissions
  - `agents/` — Agent definitions (e.g., file-manager)
  - `commands/` — Slash commands (e.g., sync-config)
- `project-desktop/` — Maps to `%USERPROFILE%\Desktop\` (project-level config)
  - `CLAUDE.md` — Project instructions
  - `.claude/settings.local.json` — Project-local settings
  - `.claude/workflows/` — Dynamic workflow scripts (`*.js`, e.g. deep-research-tiered)
- `powershell/` — Maps to `Documents\WindowsPowerShell\`
  - `Microsoft.PowerShell_profile.ps1` — Profile with claude-sp, claude-api, etc.
- `collect.ps1` — Gather local config into repo (parameterizes username)
- `deploy.ps1` — Deploy repo config to local machine (inserts local username)
- `System Prompt.txt` — Custom system prompt (repo-native, not collected/deployed)
- `claude-api.ps1` — Standalone API-mode launcher (repo-native)
- `apply-terminal-keybinding.ps1` — Repo-native; injects a Shift+Enter→newline action into the
  local Windows Terminal `settings.json`. Run automatically at the end of `deploy.ps1`.

## How Path Portability Works

Settings files contain hardcoded Windows paths like `C:\Users\<name>\...`. Since usernames differ across machines, the scripts replace the username with a `{{USERNAME}}` placeholder in the repo, and substitute the local machine's `%USERNAME%` when deploying.

## First-Time Setup on a New Machine

### Prerequisites
- Git installed and configured with GitHub credentials
- Node.js 22+ (for Claude Code)
- Claude Code installed

### Steps

1. Clone this repo (or your fork of it):
   ```powershell
   git clone https://github.com/jpeponis/claude-public.git "$env:USERPROFILE\Desktop\claude-config"
   ```

   If you plan to use this as your own ongoing sync repo, fork it first (or create your own empty repo) and clone that instead. Otherwise `sync-config push` will fail because you won't have write access to the upstream.

2. Create a GitHub Personal Access Token (only needed if you want the GitHub MCP plugin):
   - Go to https://github.com/settings/tokens?type=beta (Fine-grained tokens)
   - Click "Generate new token"
   - Name it something like "Claude Code MCP"
   - Set expiration (recommend 90 days)
   - Under "Repository access", select "All repositories" (or specific ones)
   - Under "Permissions", grant:
     - **Contents**: Read and write
     - **Issues**: Read and write
     - **Pull requests**: Read and write
     - **Metadata**: Read-only (auto-selected)
   - Click "Generate token" and copy it

3. Set the token as a persistent environment variable:
   ```powershell
   [Environment]::SetEnvironmentVariable("GITHUB_PERSONAL_ACCESS_TOKEN", "<paste-token-here>", "User")
   ```
   Then **close and reopen your terminal** for it to take effect.

4. Deploy configuration:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\claude-config\deploy.ps1"
   ```

5. Restart Claude Code and verify:
   - Settings load correctly (model, permissions)
   - The `/sync-config` slash command appears
   - The file-manager agent is available
   - The GitHub MCP plugin connects (try asking Claude a GitHub-related question)

## Ongoing Usage

### From within Claude Code
Use the `/sync-config` slash command:
- `/sync-config pull` — Pull latest config from repo and deploy locally
- `/sync-config push` — Collect local config, commit, and push to repo

### From PowerShell

**Push local changes to repo:**
```powershell
cd "$env:USERPROFILE\Desktop\claude-config"
powershell -ExecutionPolicy Bypass -File collect.ps1
git add -A && git commit -m "Update config" && git push
```

**Pull changes from repo:**
```powershell
cd "$env:USERPROFILE\Desktop\claude-config"
git pull
powershell -ExecutionPolicy Bypass -File deploy.ps1
```

## Windows Terminal Shift+Enter

`apply-terminal-keybinding.ps1` makes **Shift+Enter** insert a newline (instead of submitting)
in Claude Code under Windows Terminal. It does *not* sync the whole Terminal `settings.json`
(that file holds machine-specific profile GUIDs and lives under a package path that varies per
machine). Instead it surgically adds two idempotent blocks to whatever local `settings.json`
exists — a `sendInput` action emitting `\u001b\r` (ESC+CR, which Claude Code reads as a newline)
and a `shift+enter` keybinding mapped to it. Re-running is a no-op once present; the original
file is backed up to `.backups\terminal\` before any change. `deploy.ps1` invokes it
automatically, so `/sync-config pull` applies it on every machine.

## Dynamic Workflows

[Dynamic workflows](https://docs.claude.com/en/docs/claude-code/) are `*.js` scripts under `%USERPROFILE%\Desktop\.claude\workflows\` that orchestrate multiple subagents deterministically. They are synced as a unit (every `*.js` file in that folder), the same way agents and slash commands are. The included `deep-research-tiered.js` is a sample: it runs the search/fetch/verify fan-out on a cheap worker model (Sonnet) and reserves the current session model for question decomposition and final synthesis.

Because workflow scripts hold no machine-specific paths, they are copied verbatim (the username placeholder pass is a no-op on them).

## Adding New Files to Sync

To add a new **individual file**: edit `collect.ps1` and `deploy.ps1` and add an entry to the `$fileMappings` array.

To add a new **folder of files** (like agents, commands, or workflows): add an entry to the `$dirMappings` array with a `Filter` (e.g. `*.md` or `*.js`). All matching files in the folder are synced as a unit, and files deleted locally are removed from the repo on the next collect (and vice-versa on deploy, with a backup first).

Then run `collect.ps1` to bring the file(s) into the repo, and commit and push.
