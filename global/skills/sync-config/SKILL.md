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
- **git push/pull auth fails**: git's configured credential helper handles auth (`git config --show-origin --get-regexp '^credential'` shows which; on a machine where `gh auth setup-git` has run, github.com uses `gh`). Run `git -C "{{CONFIG_ROOT}}" push origin main` manually to diagnose. On a new machine the repo must be cloned first - see the README for the clone URL and first-time setup. (Do not reconstruct the URL from `{{USERNAME}}`: that placeholder is the *Windows* account name, not the GitHub account.)
- **"Nothing to commit"**: Local config already matches the repo. This is normal.
- **Doctor fails on "stale generated file(s)"**: someone edited a CLAUDE.md source (or a generated AGENTS.md directly) without running collect. Run `collect.ps1` to rebuild, then `deploy.ps1`.
- **Doctor warns the public repo has fallen behind**: shared files changed in the private repo since the last publish. Run `publish.ps1` (in the config repo) for the list, then `-Apply`; review and commit in the public clone it names. Only this repo has `publish.ps1`; a public fork never sees this check.
- **Merge conflicts after push pull**: Resolve manually in the repo directory, then retry.
- **Missing secret warning on pull**: Expected on a new machine. Secrets are DPAPI-encrypted locally - they can't be synced. Create them with `Set-Secret.ps1`.
- **Missing GITHUB_PERSONAL_ACCESS_TOKEN warning**: Only needed for the GitHub MCP server, not for git push/pull.
- **Deploy overwrites local edits**: The deploy script backs up existing files to `.backups/<timestamp>/` before overwriting, and a failed deploy rolls itself back from the same backups. Check there to recover.
- **`sh.exe` or `bash.exe: *** fatal error - add_item ("\??\C:\Program Files\Git", "/", ...) failed, errno 1`**, usually followed by `fatal: could not read Username for 'https://github.com': terminal prompts disabled` and `ERROR: git pull failed`: this is **not** a sync-config failure, and nothing has changed when it happens. It's an MSYS/Git-for-Windows init race ([git-for-windows/git#6368](https://github.com/git-for-windows/git/issues/6368)): while the Windows status line (which CC wraps in Git Bash and `taskkill`s on every supersede) is churning bash processes, a bash killed mid-init holds a 15s spinlock and any MSYS process starting meanwhile aborts. Two MSYS processes are exposed. One is the Bash tool's own bash, if it launches the script (exit `0xC0000005` after a ~15s hang). The other is started by **git itself on every authenticated GitHub fetch or push**: `~/.gitconfig` sets the github.com credential helper to `!'C:\Program Files\GitHub CLI\gh.exe' auth git-credential` (the form `gh auth setup-git` writes), and a `!` helper runs as a shell snippet through `sh.exe`. So **launching through the PowerShell tool does not avoid it.** **Fix: retry, spaced ~20s apart.** A loop in one PowerShell tool call is what got pull and push through on 2026-09-20:
  ```powershell
  $log = (New-TemporaryFile).FullName
  for ($i = 1; $i -le 5; $i++) {
    powershell.exe -ExecutionPolicy Bypass -File "{{CONFIG_ROOT}}/sync-config.ps1" push *> $log
    if (-not (Select-String -Path $log -Pattern 'add_item|could not read Username' -Quiet)) { break }
    Start-Sleep -Seconds 20
  }
  Get-Content $log
  ```
  Retrying is safe: a pull that fails has deployed nothing, and a push that fails at its final step leaves its commit local, which the retry sends ("Pushing N existing local commit(s)"). (Diagnosis: session 2026-09-04; the credential-helper path, 2026-09-20.)
