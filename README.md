# Claude Code Portable Configuration

A template for syncing Claude Code settings, agents, slash commands, and dynamic workflows across multiple Windows machines. This is the public version of a personal setup — feel free to fork, adapt, and add your own skills, agents, and workflows.

## Repository Structure

- `global/` — Maps to `%USERPROFILE%\.claude\` (global Claude Code config)
  - `settings.json` — Global settings and permissions
  - `agents/` — Agent definitions (e.g., file-manager, research-worker — minimal-context worker used by deep-research-tiered)
  - `commands/` — Slash commands (e.g., sync-config; api-agent — runs a prompt through a separate API-billed Claude process for features the subscription lacks, such as the 1M context window)
- `project-desktop/` — Maps to `%USERPROFILE%\Desktop\` (project-level config)
  - `CLAUDE.md` — Project instructions
  - `.claude/settings.local.json` — Project-local settings
  - `.claude/workflows/` — Dynamic workflow scripts (`*.js`, e.g. deep-research-tiered)
- `powershell/`
  - `claude-functions.ps1` — The `claude-sp` / `claude-api*` shell functions. Deployed to
    `~/.claude/claude-functions.ps1`; your PowerShell profile only gets a small managed block that
    dot-sources it. **Your profile is never replaced** — anything you keep in it is left alone. The
    block is injected into *both* profile paths, `Documents\WindowsPowerShell\` (PowerShell 5.1) and
    `Documents\PowerShell\` (PowerShell 7+), so the functions exist in whichever shell you open.
- `lib/Common.ps1` — Shared helpers (profile discovery, managed-block injection, Windows Terminal
  settings location, JSON validation).
- `secrets.json` — Names of the optional encrypted secrets and what each unlocks. Add an entry here
  if you add a skill that needs its own key.
- `collect.ps1` — Gather local config into repo (parameterizes username)
- `deploy.ps1` — Deploy repo config to local machine (inserts local username). Run it with
  `-DryRun` first to see every file it would touch without writing anything. It only ever removes
  files it previously deployed (tracked in `~/.claude/.deployed-manifest.json`), so skills and
  agents you write yourself are never deleted — and anything it does overwrite is copied to
  `.backups\<timestamp>\` first.
- `Set-Secret.ps1` / `Get-Secret.ps1` — Per-machine encrypted secret store (repo-native).
  Secrets are DPAPI-encrypted to `%USERPROFILE%\.claude\.<name>.enc` (current user, current
  machine only) and are never collected or deployed; `deploy.ps1` reports missing ones.
- `doctor.ps1` — Repo-native. Checks what is actually true on your machine after a deploy and
  prints a pass/warn/fail line per item, each failure paired with the command that fixes it.
  Run it any time you are not sure the setup took. `deploy.ps1` can only report what it *wrote*;
  this reports what *works* — the distinction matters, because a file can be written correctly to
  a location nothing reads. Exits non-zero if anything failed. `sync-config.ps1 pull` runs it
  automatically.
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

3. Store the token in the encrypted secret store:
   ```powershell
   & "$env:USERPROFILE\Desktop\claude-config\Set-Secret.ps1" -Name github-token
   ```
   This prompts for the value with the input hidden, then DPAPI-encrypts it to
   `~/.claude/.github-token.enc` — readable only by your Windows account on this machine.
   `claude-functions.ps1` loads it into the environment when a shell starts, so the plaintext
   never lands in your registry, your shell history, or a file.

   Do **not** set it as a plain `[Environment]::SetEnvironmentVariable(...)` User variable. That
   stores the token in the registry in the clear, and — because the loader only reads the encrypted
   store when the variable is unset — it silently shadows the encrypted path, so you get the weaker
   of the two and no indication of it.

4. Deploy configuration. Add `-DryRun` first if you want to see exactly what it would touch:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\claude-config\deploy.ps1"
   ```

5. Verify the install:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\claude-config\doctor.ps1"
   ```
   You want `all checks passed`. Warnings are usually fine — an optional secret you skipped, or
   Windows Terminal not being installed. Failures come with the command that fixes them.

6. **Open a new terminal tab**, then restart Claude Code. The shell functions only exist in shells
   started after the deploy, and Claude Code reads its settings at launch. Then try:
   - `claude-sp` — the main way in (see "Start here" below)
   - `/sync-config` and `/api-agent` should appear in the slash-command list
   - the `file-manager` agent should be available

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

[Dynamic workflows](https://docs.claude.com/en/docs/claude-code/) are `*.js` scripts under `%USERPROFILE%\Desktop\.claude\workflows\` that orchestrate multiple subagents deterministically. They are synced as a unit (every `*.js` file in that folder), the same way agents and slash commands are. The included `deep-research-tiered.js` is a sample: the session model decomposes the question into search angles and key assertions, worker-model agents fan out to search and fetch sources, each extracted claim gets a fast Haiku scan that escalates doubtful or key-assertion claims to two Sonnet adversarial-lens votes, and the session model synthesizes a cited report and runs a completeness critique against the key assertions. Every spawned agent uses the lightweight `research-worker` agent definition (`global/agents/research-worker.md`) — a barebones system prompt with no MCP tools or skills.

Because workflow scripts hold no machine-specific paths, they are copied verbatim (the username placeholder pass is a no-op on them).

## Adding New Files to Sync

To add a new **individual file**: edit `collect.ps1` and `deploy.ps1` and add an entry to the `$fileMappings` array.

To add a new **folder of files** (like agents, commands, or workflows): add an entry to the `$dirMappings` array with a `Filter` (e.g. `*.md` or `*.js`). All matching files in the folder are synced as a unit, and files deleted locally are removed from the repo on the next collect (and vice-versa on deploy, with a backup first).

Then run `collect.ps1` to bring the file(s) into the repo, and commit and push.
