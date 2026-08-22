---
name: sync-config
description: Push or pull this machine's agent configuration - Claude Code and Codex CLI settings, skills, agents, workflows, statusline, generated AGENTS.md files and shell functions - through the private claude-config git repo, then verify the result with doctor. Use when the user wants to sync, back up or restore their Claude Code or Codex setup, propagate a config change to their other machines, or pick up changes made on another machine.
---

# Sync Agent Configuration

Keeps Claude Code and Codex CLI configuration in sync across machines via a private
GitHub repo (`{{CONFIG_ROOT}}`).

## Usage
/sync-config [push|pull]

## What gets synced
Declared once, in `Get-ArtifactManifest` (`lib/Common.ps1`). Claude: settings, skills,
agents, workflows, the CLAUDE.md files, statusline, shell functions. Codex: the
`personal` profile, agent TOMLs, `codex-functions.ps1`, and the **generated** AGENTS.md
files (built from the CLAUDE.md files - never edit a deployed AGENTS.md; edit the
sources). Shared skills deploy to both `~/.claude/skills` and `~/.agents/skills` and
are collected from the `~/.claude` copy only.

**Not** the PowerShell profile: deploy adds a small managed block to each profile that
dot-sources `~/.claude/claude-functions.ps1` and `~/.codex/codex-functions.ps1`, and
never rewrites anything else in it. Sensitive files (API keys, OAuth tokens) are
excluded - they are DPAPI-encrypted per machine. Codex machine state (`auth.json`,
`config.toml`, databases, trust records) never syncs. Username is parameterized
(`{{USERNAME}}`) so the repo is machine-portable.

## Behavior

The script is `sync-config.ps1` in the config repo. Always quote `"$HOME/..."` in bash so the variable expands. Do NOT use `$env:USERPROFILE`.

### Pull (default)
Run:
```
powershell.exe -ExecutionPolicy Bypass -File "{{CONFIG_ROOT}}/sync-config.ps1" pull
```
Report output to the user. Remind them to restart Claude Code if settings changed.

### Push
1. Run with `-DryRun` first:
```
powershell.exe -ExecutionPolicy Bypass -File "{{CONFIG_ROOT}}/sync-config.ps1" push -DryRun
```
2. Show the user what will be committed and **ask for confirmation**.
3. If confirmed, run without `-DryRun`:
```
powershell.exe -ExecutionPolicy Bypass -File "{{CONFIG_ROOT}}/sync-config.ps1" push
```

### Default
If no argument is provided, default to **pull**.

## Divergence refusals

If push stops with "REFUSING to collect", the repo moved past this machine's last
deploy and a managed file disagrees with the installed copy - collecting would
silently overwrite another machine's work. Tell the user which artifacts it named,
then:
- Almost always right: run `deploy.ps1` to take the repo's newer version (the local
  copy is backed up to `.backups/`), then push again.
- Only if the user explicitly wants this machine's copy to win: run
  `collect.ps1 -Force`, then push.
Never pick `-Force` without asking.

## Troubleshooting
- **git push/pull auth fails**: Git credential manager handles auth. Run `git -C "{{CONFIG_ROOT}}" push origin main` manually to diagnose. On a new machine the repo must be cloned first - see the README for the clone URL and first-time setup. (Do not reconstruct the URL from `{{USERNAME}}`: that placeholder is the *Windows* account name, not the GitHub account.)
- **"Nothing to commit"**: Local config already matches the repo. This is normal.
- **Doctor fails on "stale generated file(s)"**: someone edited a CLAUDE.md source (or a generated AGENTS.md directly) without running collect. Run `collect.ps1` to rebuild, then `deploy.ps1`.
- **Doctor warns codex is newer than certified**: a Codex update landed. Re-run doctor's Codex checks and a quick codex-sp session on this machine; if healthy, raise `certified` in `compat.json` and push.
- **Merge conflicts after push pull**: Resolve manually in the repo directory, then retry.
- **Missing secret warning on pull**: Expected on a new machine. Secrets are DPAPI-encrypted locally - they can't be synced. Create them with `Set-Secret.ps1`.
- **Missing GITHUB_PERSONAL_ACCESS_TOKEN warning**: Only needed for the GitHub MCP server, not for git push/pull.
- **Deploy overwrites local edits**: The deploy script backs up existing files to `.backups/<timestamp>/` before overwriting, and a failed deploy rolls itself back from the same backups. Check there to recover.
