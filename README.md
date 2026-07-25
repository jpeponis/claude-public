# Claude Code Portable Configuration

A template for syncing Claude Code settings, launchers, agents, slash commands, a statusline,
and dynamic workflows across multiple Windows machines. It installs in one command, checks its
own work, and can put back anything a deploy overwrote. This is the public version of a personal
setup — feel free to fork, adapt, and add your own skills, agents, and workflows.

## Repository Structure

- `global/` — Maps to `%USERPROFILE%\.claude\` (global Claude Code config)
  - `settings.json` — Global settings, permissions, model, and statusline registration
  - `statusline-command.ps1` — Statusline showing user@machine, the current directory and git
    branch, subscription usage for the current five-hour window, time until that window resets,
    and how full the context window is
  - `agents/` — Agent definitions (file-manager, for bulk file operations that would otherwise
    eat the main context; research-worker, the minimal-context worker used by
    deep-research-tiered)
  - `commands/` — Slash commands (sync-config, api-agent)
- `project-desktop/` — Maps to `%USERPROFILE%\Desktop\` (project-level config)
  - `CLAUDE.md` — Project instructions
  - `.claude/settings.local.json` — Project-local settings
  - `.claude/workflows/` — Dynamic workflow scripts (`*.js`, e.g. deep-research-tiered)
- `powershell/claude-functions.ps1` — Maps to `%USERPROFILE%\.claude\`, dot-sourced by both
  PowerShell profiles. Defines `claude-sp`, `claude-spsp`, and the `claude-api*` launchers.
- `bootstrap.ps1` — One-command install: forks, clones, deploys, verifies (public-repo native)
- `collect.ps1` — Gather local config into repo (parameterizes username)
- `deploy.ps1` — Deploy repo config to local machine (inserts local username)
- `sync-config.ps1` — `push` / `pull` wrapper around the two above
- `doctor.ps1` — Report what actually works on this machine; exits non-zero if anything failed
- `restore.ps1` — Restore from the timestamped backups `deploy.ps1` writes to `.backups\`
- `Set-Secret.ps1` / `Get-Secret.ps1` — Per-machine encrypted secret store (repo-native).
  Secrets are DPAPI-encrypted to `%USERPROFILE%\.claude\.<name>.enc` (current user, current
  machine only) and are never collected or deployed; `deploy.ps1` warns about missing ones.
- `secrets.json` — Registry of which secrets exist and what each one unlocks
- `lib/Common.ps1` — Shared helpers: profile discovery, managed-block injection, JSON validation
- `System Prompt.txt` — Custom system prompt (repo-native, not collected/deployed)
- `claude-api.ps1` — Standalone API-mode launcher (repo-native)
- `apply-terminal-keybinding.ps1` — Repo-native; injects a Shift+Enter→newline action into the
  local Windows Terminal `settings.json`. Run automatically at the end of `deploy.ps1`.

The scripts run from the repo; `global/` and `project-desktop/` are what gets deployed.

## How Path Portability Works

Settings files contain hardcoded Windows paths like `C:\Users\<name>\...`. Since usernames differ
across machines, the scripts replace the username with a `{{USERNAME}}` placeholder in the repo,
and substitute the local machine's `%USERNAME%` when deploying. After collecting, `collect.ps1`
verifies that no real username leaked into the repo.

One key is deliberately excluded from collection: `model` in `global/settings.json`. It records
whichever model the last session happened to be using, so collecting it would let one machine's
passing choice change the model on another at the next pull. The repo's value is the default;
edit the file to change it.

## First-Time Setup on a New Machine

### Prerequisites
- Windows
- [Git](https://git-scm.com/) installed and configured with GitHub credentials
- [GitHub CLI](https://cli.github.com/), authenticated with `gh auth login` (used to fork)
- [Node.js 22+](https://nodejs.org/)
- Claude Code (`npm install -g @anthropic-ai/claude-code`)

`bootstrap.ps1` checks each one and stops with the exact command to fix it, rather than
half-installing.

### Steps

1. Run the installer:
   ```powershell
   irm https://raw.githubusercontent.com/jpeponis/claude-public/main/bootstrap.ps1 | iex
   ```

   It forks this repo to your GitHub account, clones the fork to `<Desktop>\claude-config`,
   deploys the configuration, and runs `doctor.ps1` against the result. It prints the plan and
   asks before it changes anything.

   To read what it would do without doing it — worth doing, since this is a script from the
   internet:
   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jpeponis/claude-public/main/bootstrap.ps1))) -DryRun
   ```

   Other flags: `-NoFork` (read-only clone, no config push), `-Dest <path>`, `-Yes`.

   The fork is the default rather than an afterthought. `sync-config push` pushes to `origin`,
   so a plain clone of someone else's repo is a setup whose push half is broken from the first
   day.

2. **Open a new terminal tab.** The shell functions are defined by a block in your PowerShell
   profiles, so they only exist in shells started after the deploy.

3. Start Claude Code and verify:
   ```powershell
   claude-sp
   ```
   - Settings load correctly (model, permissions)
   - The statusline appears at the bottom of the session
   - The `/sync-config` and `/api-agent` slash commands appear
   - The file-manager agent is available

### Installing by Hand

Clone the repo (fork it first if you want `/sync-config push` to work), then deploy and verify:

```powershell
git clone https://github.com/<you>/claude-public.git "$env:USERPROFILE\Desktop\claude-config"
cd "$env:USERPROFILE\Desktop\claude-config"
powershell -ExecutionPolicy Bypass -File deploy.ps1
powershell -ExecutionPolicy Bypass -File doctor.ps1
```

### Optional: GitHub Personal Access Token

The GitHub MCP plugin is enabled in `settings.json` and needs a token to do anything. Everything
else works without it.

1. Go to https://github.com/settings/tokens?type=beta (Fine-grained tokens)
2. Click "Generate new token"
3. Name it something like "Claude Code"
4. Set expiration (if you want it to expire)
5. Under "Repository access", select "All repositories" (or specific ones)
6. Under "Permissions", grant:
   - **Contents**: Read and write
   - **Issues**: Read and write
   - **Pull requests**: Read and write
   - **Metadata**: Read-only (auto-selected)
7. Click "Generate token" and copy it
8. Store it in the encrypted secret store:
   ```powershell
   .\Set-Secret.ps1 -Name github-token
   ```
   The prompt hides the input and DPAPI-encrypts the token to `~/.claude/.github-token.enc`,
   readable only by your Windows account on that machine. `claude-functions.ps1` loads it into
   the environment at shell start, so the plaintext never lands in your registry, your shell
   history, or a file.

Setting `GITHUB_PERSONAL_ACCESS_TOKEN` as a plain user environment variable instead stores the
token in the registry in clear text, and the loader only reads the encrypted store when the
variable is unset — so doing both silently gives you the weaker of the two.

## Launchers

`claude-sp` is the main launch command: Claude Code with the system prompt from `System Prompt.txt` and
permissions in auto mode. `claude-spsp` is the same thing plus `--dangerously-skip-permissions`,
which stops it asking before it acts — worth watching `claude-sp` work for a while first, so you
know what you are agreeing to in advance.

**On cost:** the shipped settings are Opus at `xhigh` effort. I recommend trying that to then
judge whether a cheaper or more expensive model will be good enough for your work.

## Ongoing Usage

One command moves your configuration between machines. Synced: `global/settings.json`, slash
commands, agents, the statusline, the shell functions, `CLAUDE.md`, project-local settings, and
workflow scripts. Not synced: the encrypted secrets, which are per-machine by construction, and
your PowerShell profile — the functions live in their own file that the profile sources, so
nothing else in the profile is touched.

### From within Claude Code
Use the `/sync-config` slash command:
- `/sync-config pull` — Pull latest config from repo, deploy locally, then run `doctor.ps1`
- `/sync-config push` — Collect local config, commit, and push to repo

### From PowerShell

```powershell
cd "$env:USERPROFILE\Desktop\claude-config"
powershell -ExecutionPolicy Bypass -File sync-config.ps1 push   # collect, commit, push
powershell -ExecutionPolicy Bypass -File sync-config.ps1 pull   # pull, deploy, verify
```

Or run the underlying scripts directly:

```powershell
powershell -ExecutionPolicy Bypass -File collect.ps1
git add -A
git commit -m "Update config"
git push
```

Push works because you forked; pushing to a repo you do not own does not. To take later changes
from upstream:

```powershell
git -C "$env:USERPROFILE\Desktop\claude-config" pull upstream main
```

### Optional: Anthropic API Key

Only needed for API mode. Store it similarly to the above GitHub token:

```powershell
.\Set-Secret.ps1 -Name api-key
```

### API Mode

API mode runs Claude Code against pay-as-you-go API billing rather than your subscription or usage
credits. **It is billed per token, separately from your subscription.** With the `api-key` secret
stored:

- `claude-api`, `claude-api-sp`, `claude-api-spsp` — shell functions, the API-billed
  counterparts of the launchers above
- `claude-api.ps1 -Extended` — standalone launcher; `-Extended` requests the 1M context window,
  and `-SP` / `-SPSP` add the system prompt and skipped permissions
- `/api-agent` — from inside a subscription session, shells a single prompt out to an
  API-billed process

The model defaults to the alias `opus`, which always resolves to the current Opus, so it does not
go stale when a new model ships. Pass `-Model` to pin a specific one.

One note (noted at the top of `claude-functions.ps1` as well): `claude-sp` uses
`--system-prompt-file`, which *replaces* Claude Code's default system prompt, while
`claude-api-sp` uses `--append-system-prompt-file`, which *appends* to it.

## Verifying and Recovering

```powershell
.\doctor.ps1
```

`doctor.ps1` reports what is actually true on this machine: Claude Code and Node versions,
settings that parse, every command and agent the repo ships being present, the statusline
actually executing, both PowerShell profiles wired up, the Shift+Enter binding, and secrets that
actually decrypt. Each failure prints the command that fixes it, and the script exits non-zero if
anything failed. `/sync-config pull` runs it automatically.

It exists because `deploy.ps1` can only report what it *wrote*, which can be entirely true while
the outcome is still wrong — a file written perfectly to a location nothing reads is the
motivating case.

```powershell
.\restore.ps1                 # list what can be restored
.\restore.ps1 -Latest -DryRun # preview
.\restore.ps1 -Latest         # put it back
```

Every deploy first backs up what it is about to overwrite into `.backups\<timestamp>\`, with a
manifest recording where each file came from, so `restore.ps1` puts files back exactly there
instead of inferring it. Files that already match are skipped, so recovering one bad file
rewrites only that file.

`deploy.ps1` is additive by design. It adds a small marked block to your PowerShell profiles
rather than replacing them, and it only ever deletes files it previously deployed itself
(tracked in `~/.claude/.deployed-manifest.json`), so slash commands and agents you write yourself
are never touched.

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

[Dynamic workflows](https://docs.claude.com/en/docs/claude-code/) are `*.js` scripts under
`%USERPROFILE%\Desktop\.claude\workflows\` that orchestrate multiple subagents deterministically.
They are synced as a unit (every `*.js` file in that folder), the same way agents and slash
commands are. The included `deep-research-tiered.js` is a sample: the session model decomposes the
question into search angles and key assertions, worker-model agents fan out to search and fetch
sources, each extracted claim gets a fast Haiku scan that escalates doubtful or key-assertion
claims to two Sonnet adversarial-lens votes, and the session model synthesizes a cited report and
runs a completeness critique against the key assertions. Every spawned agent uses the lightweight
`research-worker` agent definition (`global/agents/research-worker.md`) — a barebones system
prompt with no MCP tools or skills.

`enableWorkflows` ships as `false` in `global/settings.json`, to keep the Workflow tool's large
schema out of context in ordinary sessions. The deployed `CLAUDE.md` instructs Claude to set it to
`true` when a workflow is actually needed and back to `false` afterwards; the setting hot-reloads
on every request, so no restart is involved.

Because workflow scripts hold no machine-specific paths, they are copied verbatim (the username
placeholder pass is a no-op on them).

## Adding New Files to Sync

To add a new **slash command**, drop a `.md` file in `global/commands/`. For a new **agent**, a
`.md` file in `global/agents/`. For a new **workflow**, a `.js` file in
`project-desktop/.claude/workflows/`. For a new **secret**, add a `{name, purpose}` entry to
`secrets.json`; `deploy.ps1` and `doctor.ps1` then report on it automatically.

To add a new **individual file**: edit `collect.ps1` and `deploy.ps1` and add an entry to the
`$fileMappings` array.

To add a new **folder of files** (like agents, commands, or workflows): add an entry to the
`$dirMappings` array with a `Filter` (e.g. `*.md` or `*.js`). All matching files in the folder are
synced as a unit, and files deleted locally are removed from the repo on the next collect (and
vice-versa on deploy, with a backup first).

Then run `collect.ps1` to bring the file(s) into the repo, and commit and push — or just
`/sync-config push`, which does all three.

## Implementation Notes

- **Both PowerShell editions are wired.** Windows PowerShell 5.1 and PowerShell 7 read different
  profile paths. `deploy.ps1` injects its managed block into both, so the functions exist in
  whichever shell you open. `doctor.ps1` checks each one, and reports which shell Windows
  Terminal opens by default.
- **Repo `.ps1` files are pure ASCII, on purpose.** Windows PowerShell 5.1 reads a BOM-less file
  as ANSI, so a stray em-dash decodes into a smart quote that PowerShell treats as a string
  delimiter — fatal inside a double-quoted string. `doctor.ps1` enforces it. Markdown is fine.
