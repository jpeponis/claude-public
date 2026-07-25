# Claude Code, set up

A working Claude Code configuration for Windows — launchers, a system prompt, agents,
slash commands, a statusline, and a sync mechanism that carries all of it to your next
machine. Install it in one command, verify it in one more, and undo it if you don't like it.

This started as one person's setup, and it's shared because bootstrapping someone else's
Claude Code by hand costs an afternoon. Fork it and it becomes yours.

## What you get

- **`claude-sp`** — Claude Code with a custom system prompt and permissions in auto mode.
  The main way in. Also `claude-spsp`, which additionally skips permission prompts.
- **`/sync-config`** — push your whole configuration to your fork, pull it onto another
  machine. Settings, slash commands, agents, workflows, the system prompt, the launchers.
- **A statusline** showing user@machine, the current directory and git branch, context
  remaining, and elapsed session time.
- **`file-manager`** — an agent for bulk file operations, so they don't eat your main context.
- **`/api-agent`** and **`claude-api*`** — run a prompt through pay-as-you-go API billing
  instead of your subscription, for the 1M-token context window.
- **A deep-research workflow** — a multi-agent script that fans out across sources, verifies
  claims on a cheap model, escalates the doubtful ones, and writes a cited report.
- **An encrypted secret store** — API keys held by Windows DPAPI, readable only by your
  account on your machine. Never committed, never synced.
- **Shift+Enter for a newline** in Windows Terminal, instead of submitting the message.
- **`doctor.ps1` and `restore.ps1`** — check what actually works; put back what a deploy changed.

## Install

```powershell
irm https://raw.githubusercontent.com/jpeponis/claude-public/main/bootstrap.ps1 | iex
```

It forks this repo to your GitHub account, clones the fork to `<Desktop>\claude-config`,
deploys the configuration, and verifies the result. It shows you the plan and asks before
it changes anything.

To read what it would do without doing it — worth doing, since you're about to run a script
from the internet:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jpeponis/claude-public/main/bootstrap.ps1))) -DryRun
```

Other flags: `-NoFork` (read-only clone, no config push), `-Dest <path>`, `-Yes`.

**Requirements:** Windows, [Git](https://git-scm.com/), [GitHub CLI](https://cli.github.com/)
(`gh auth login`), [Node.js 22+](https://nodejs.org/), and Claude Code
(`npm install -g @anthropic-ai/claude-code`). Bootstrap checks each one and stops with the
exact command to fix it rather than half-installing.

Prefer to do it by hand? Clone the repo and run `deploy.ps1`, then `doctor.ps1`. Fork first
if you want `/sync-config push` to work.

## Start here

**Open a new terminal tab** — the shell functions only exist in shells started after the
deploy — then:

```powershell
claude-sp
```

That's Claude Code with the system prompt from `System Prompt.txt` and permissions in auto
mode. It's what gets used day to day.

`claude-spsp` is the same thing plus `--dangerously-skip-permissions`. It stops asking before
it acts. Watch `claude-sp` work for a while before you reach for it, so you know what you're
agreeing to in advance.

**On cost:** the shipped settings are Opus at `xhigh` effort. That is deliberate — it's the
full-capability setting, and it's the right baseline for judging whether the cheaper models
are good enough for your work. It will also consume a Pro subscription quickly. Change
`"model"` in `global/settings.json` to `sonnet` or `haiku` (and `"effortLevel"` to `high` or
`medium`) and re-run `deploy.ps1` when you want to trade capability for headroom.

Inside Claude Code, `/sync-config` and `/api-agent` should appear in the slash-command list,
and `file-manager` in the agent list.

## Sync

The point of the repo. One command moves your configuration between machines.

```powershell
/sync-config push    # collect this machine's config, commit, push to your fork
/sync-config pull    # pull from your fork, deploy here, then verify
```

Or from PowerShell directly: `sync-config.ps1 push` / `sync-config.ps1 pull`.

**What's synced:** `global/settings.json`, slash commands, agents, the statusline, the shell
functions, `CLAUDE.md`, project-local settings, and workflow scripts. **What isn't:** the
encrypted secrets (per-machine by construction), and your PowerShell profile — the functions
live in their own file that your profile sources, so nothing else in your profile is touched.

**How it moves between machines:** settings files contain absolute paths with your Windows
username in them. `collect.ps1` rewrites your username to `{{USERNAME}}` on the way into the
repo, and `deploy.ps1` substitutes the local one on the way out. Collect verifies afterwards
that no real username leaked into the repo.

**Because you forked it, push works.** Pushing to a repo you don't own doesn't — which is why
bootstrap forks by default. To take later changes from upstream:

```powershell
git -C "$env:USERPROFILE\Desktop\claude-config" pull upstream main
```

One key is deliberately *not* collected: `model` in `global/settings.json`. It tracks whichever
model you happened to be using, so collecting it would let one machine's passing choice
silently change the model on another. The repo's value is the default; edit the file to change it.

## Verify and recover

```powershell
.\doctor.ps1
```

Reports what is actually true on this machine: Claude Code and Node versions, settings that
parse, every command and agent the repo ships being present, the statusline actually
executing, both PowerShell profiles wired up, the Shift+Enter binding, and secrets that
actually decrypt. Each failure prints the command that fixes it; it exits non-zero if
anything failed, and `/sync-config pull` runs it automatically.

This exists because `deploy.ps1` can only report what it *wrote*. A file can be written
perfectly to a location nothing reads — that gap survived four months here before a doctor
script found it.

```powershell
.\restore.ps1                 # list what can be restored
.\restore.ps1 -Latest -DryRun # preview
.\restore.ps1 -Latest         # put it back
```

Every deploy backs up what it's about to overwrite into `.backups\<timestamp>\` with a
manifest recording where each file came from. Restore puts them back exactly there, and skips
files that already match, so recovering one bad file rewrites only that file.

`deploy.ps1` is additive by design: it adds a small marked block to your PowerShell profiles
rather than replacing them, and it only ever deletes files it previously deployed itself
(tracked in `~/.claude/.deployed-manifest.json`), so slash commands and agents you write
yourself are never touched.

## Optional extras

Everything above works without any of this.

### GitHub MCP

The GitHub plugin is enabled in settings and needs a token to do anything.

1. Create a fine-grained token at <https://github.com/settings/tokens?type=beta> with
   **Contents**, **Issues**, and **Pull requests** set to read/write.
2. Store it encrypted:
   ```powershell
   .\Set-Secret.ps1 -Name github-token
   ```

It prompts with the input hidden and DPAPI-encrypts it to `~/.claude/.github-token.enc`,
readable only by your Windows account on that machine. `claude-functions.ps1` loads it into
the environment at shell start, so the plaintext never lands in your registry, your shell
history, or a file.

Don't set it as a plain user environment variable instead. That stores the token in the
registry in clear text, and the loader only reads the encrypted store when the variable is
unset — so you'd silently get the weaker of the two.

### API mode

Runs Claude Code against pay-as-you-go API billing rather than your subscription, which is
how you get the 1M-token context window. Needs an Anthropic API key:

```powershell
.\Set-Secret.ps1 -Name api-key
```

Then `claude-api`, `claude-api-sp`, `claude-api-spsp`, or `claude-api.ps1 -Extended`. Inside
a subscription session, `/api-agent` shells one prompt out to an API-billed process. **This
is billed per token, separately from your subscription.**

The model defaults to the alias `opus`, which always resolves to the current Opus, so it
doesn't go stale when a new model ships. Pass `-Model` to pin a specific one.

> **One deliberate inconsistency.** `claude-sp` uses `--system-prompt-file`, which *replaces*
> Claude Code's default system prompt. `claude-api-sp` uses `--append-system-prompt-file`,
> which *appends* to it. That difference is intentional, not drift — it's noted at the top of
> `claude-functions.ps1` too, so nobody "fixes" it later.

## Adding your own

- **Slash command:** drop a `.md` file in `global/commands/`.
- **Agent:** drop a `.md` file in `global/agents/`.
- **Workflow:** drop a `.js` file in `project-desktop/.claude/workflows/`.
- **Secret:** add a `{name, purpose}` entry to `secrets.json`; `deploy.ps1` and `doctor.ps1`
  start reporting on it automatically.
- **A whole new file or folder to sync:** add an entry to `$fileMappings` or `$dirMappings` in
  both `collect.ps1` and `deploy.ps1`.

Then `/sync-config push`. Directory-based sets sync as a unit, so deleting a file locally
removes it from the repo on the next collect, and vice versa on deploy — with a backup first.

## What's in the repo

| Path | |
|---|---|
| `bootstrap.ps1` | One-command install. Forks, clones, deploys, verifies. |
| `deploy.ps1` | Repo → machine. `-DryRun` previews every change. |
| `collect.ps1` | Machine → repo. |
| `sync-config.ps1` | `push` / `pull` around the two above. |
| `doctor.ps1` | Reports what actually works. Exits non-zero on failure. |
| `restore.ps1` | Restores from `.backups\<timestamp>\`. |
| `Set-Secret.ps1` / `Get-Secret.ps1` | Per-machine encrypted secret store. |
| `apply-terminal-keybinding.ps1` | Adds the Shift+Enter binding to Windows Terminal. |
| `claude-api.ps1` | Standalone API-mode launcher. |
| `lib/Common.ps1` | Shared helpers: profile discovery, managed block, JSON validation. |
| `System Prompt.txt` | The system prompt `claude-sp` loads. |
| `global/` | → `%USERPROFILE%\.claude\` (settings, commands, agents, statusline). |
| `project-desktop/` | → your Desktop (`CLAUDE.md`, project settings, workflows). |
| `powershell/claude-functions.ps1` | → `~/.claude/`, sourced by both PowerShell profiles. |
| `secrets.json` | Which secrets exist and what each unlocks. |

The scripts run from the repo; `global/` and `project-desktop/` are what gets deployed.

## Notes

- **Both PowerShell editions are wired.** Windows PowerShell 5.1 and PowerShell 7 read
  different profile paths. Deploy injects into both, so the functions exist in whichever shell
  you open. `doctor.ps1` checks each one, and reports which shell Windows Terminal opens by
  default.
- **Repo `.ps1` files are pure ASCII, on purpose.** Windows PowerShell 5.1 reads a BOM-less
  file as ANSI, so a stray em-dash decodes into a smart quote that PowerShell treats as a
  string delimiter — fatal inside a double-quoted string. `doctor.ps1` enforces it. Markdown
  is fine.
- **Windows Terminal settings aren't synced.** That file holds machine-specific profile GUIDs.
  `apply-terminal-keybinding.ps1` surgically adds two idempotent blocks to whatever local
  `settings.json` exists, backing it up first.
