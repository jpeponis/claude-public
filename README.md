# Claude Code Portable Configuration

A template for syncing Claude Code settings, launchers, agents, skills, a statusline, and
dynamic workflows across multiple Windows machines. It installs in one command, checks its
own work, and can put back anything a deploy overwrote. This is the public version of a personal
setup — feel free to fork, adapt, and add your own skills, agents, and workflows.

## Repository Structure

- `global/` — Maps to `%USERPROFILE%\.claude\` (global Claude Code config)
  - `settings.json` — Global settings, permissions, model, and statusline registration
  - `CLAUDE.md` — User-level instructions: what holds wherever you start a session
  - `statusline-command.ps1` — Statusline showing user@machine, the current directory and git
    branch, subscription usage for the current five-hour window, time until that window resets,
    and how full the context window is
  - `agents/` — Agent definitions (file-manager, for bulk file operations that would otherwise
    eat the main context; research-worker, the minimal-context worker used by
    deep-research-tiered)
  - `skills/<name>/SKILL.md` — Skills, one directory each (sync-config,
    deep-research-tiered). The directory name is the slash command, and the whole directory
    syncs, so a skill can carry the scripts and reference files it depends on
- `project-desktop/` — Maps to your Desktop (project-level config). Resolved with
  `[Environment]::GetFolderPath('Desktop')` rather than `%USERPROFILE%\Desktop`, so it still
  lands in the right place when OneDrive Known Folder Move has redirected Desktop — which is
  the default on a consumer Windows 11 setup
  - `CLAUDE.md` — Instructions scoped to the Desktop itself
  - `.claude/settings.local.json` — Project-local settings
  - `.claude/workflows/` — Dynamic workflow scripts (`*.js`, e.g. deep-research-tiered)
- `powershell/claude-functions.ps1` — Maps to `%USERPROFILE%\.claude\`, dot-sourced by both
  PowerShell profiles. Defines `claude-sp`, `claude-spsp`, the `claude-or*` launchers, and
  `codex-sp`.
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
- `lib/Common.ps1` — Shared helpers: the sync plan (what gets synced, declared once and read by
  collect, deploy and doctor), file enumeration, token substitution, profile discovery,
  managed-block injection, backup enumeration, JSON validation
- `System Prompt.txt` — Custom system prompt (repo-native, not collected/deployed)
- `apply-terminal-keybinding.ps1` — Repo-native; injects a Shift+Enter→newline action into the
  local Windows Terminal `settings.json`. Run automatically at the end of `deploy.ps1`.

The scripts run from the repo; `global/` and `project-desktop/` are what gets deployed.

## How Path Portability Works

Config files contain absolute Windows paths, and they differ on every machine. Three tokens stand
in for the parts that vary. `collect.ps1` writes them when it pulls config into the repo, and
`deploy.ps1` expands them on the way back out:

| Token | Expands to |
| --- | --- |
| `{{USERNAME}}` | your Windows account name |
| `{{DESKTOP}}` | your real Desktop, forward-slashed |
| `{{CONFIG_ROOT}}` | this repo's absolute path, forward-slashed |

Collect matches case-insensitively and accepts either slash direction, since a path on disk may be
spelled differently than `%USERNAME%` reports it. Deploy substitutes literally, in forward-slash
form, which both PowerShell and Git Bash accept. Afterwards `collect.ps1` verifies that no real
username survived into the repo, and `doctor.ps1` fails if any synced markdown hardcodes a
Desktop path.

Markdown needs the tokens as much as JSON does. A skill telling Claude to run
`$HOME/Desktop/claude-config/something.ps1` is wrong on any machine where OneDrive Known Folder
Move has redirected Desktop — the instructions are executed, so a path in prose is as real as a
path in a settings file.

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
   - The `/sync-config` and `/deep-research-tiered` slash commands appear
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

One command moves your configuration between machines. Synced: `global/settings.json`, skills,
agents, the statusline, the shell functions, both `CLAUDE.md` files, project-local settings, and
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

### Optional: OpenRouter Key

Only needed for OpenRouter mode. Store it similarly to the above GitHub token:

```powershell
.\Set-Secret.ps1 -Name openrouter-key
```

### OpenRouter Mode

OpenRouter mode routes the whole session through OpenRouter's Anthropic-compatible endpoint
(`ANTHROPIC_BASE_URL=https://openrouter.ai/api`), with gateway model discovery on, so `/model`
lists the OpenRouter catalog. **Everything in such a session — Claude models included — bills
your OpenRouter key, not your subscription.** With the `openrouter-key` secret stored:

- `claude-or`, `claude-or-sp`, `claude-or-spsp` — shell functions, the OpenRouter-billed
  counterparts of the launchers above

The endpoint is session-wide: the main model and every native subagent share it. One caveat:
`claude-or` drops `ENABLE_TOOL_SEARCH` for its session, because deferred tool definitions are
Anthropic-only and other models through the gateway reject them — so an OpenRouter session
loads every MCP tool definition eagerly and pays that context cost up front.

One note (noted at the top of `claude-functions.ps1` as well): `claude-sp` uses
`--system-prompt-file`, which *replaces* Claude Code's default system prompt, while
`claude-or-sp` uses `--append-system-prompt-file`, which *appends* to it.

## Verifying and Recovering

```powershell
.\doctor.ps1
```

`doctor.ps1` reports what is actually true on this machine: Claude Code and Node versions,
settings that parse, every skill and agent the repo ships being present, every deployed file
still *matching* the repo, the statusline actually executing, both PowerShell profiles wired up,
the Shift+Enter binding, and secrets that actually decrypt. Each failure prints the command that
fixes it, and the script exits non-zero if anything failed. `/sync-config pull` runs it
automatically and passes its exit code through.

It exists because `deploy.ps1` can only report what it *wrote*, which can be entirely true while
the outcome is still wrong — a file written perfectly to a location nothing reads is the
motivating case.

The match check earns its place for a quieter reason: editing `~/.claude/skills/foo/SKILL.md`
directly is a perfectly normal way to work on a skill, and nothing otherwise tells you the repo
now disagrees — until a later deploy overwrites the edit. It warns rather than fails, because
either direction can be the right one: `collect.ps1` keeps the local version, `deploy.ps1` takes
the repo's.

A final section checks the content rather than the plumbing: that every skill declares a
`description`, that no synced markdown hardcodes a Desktop path, and that `research-worker.md`
still agrees with `System Prompt.txt`, which it deliberately duplicates. These are the kind of
mistake every other check passes straight over.

To see what a deploy would change without changing anything:

```powershell
.\deploy.ps1 -DryRun
```

It prints every write, deletion, profile edit and environment change, and performs none of them.

```powershell
.\restore.ps1                 # list what can be restored
.\restore.ps1 -Latest -DryRun # preview
.\restore.ps1 -Latest         # put it back
```

Every deploy first backs up the files it is about to overwrite into `.backups\<timestamp>\`, with
a manifest recording where each file came from, so `restore.ps1` puts files back exactly there
instead of inferring it. Only files whose content actually changes are copied, so a deploy that
changes nothing creates no backup directory at all and the newest 20 directories it keeps are 20
real changes rather than 20 runs. Pass `-KeepBackups <n>` to change how many are kept.

`deploy.ps1` is additive by design. It adds a small marked block to your PowerShell profiles
rather than replacing them, and it only ever deletes files it previously deployed itself
(tracked in `~/.claude/.deployed-manifest.json`), so skills and agents you write yourself are
never touched.

## Windows Terminal Shift+Enter

`apply-terminal-keybinding.ps1` makes **Shift+Enter** insert a newline (instead of submitting)
in Claude Code under Windows Terminal. It does *not* sync the whole Terminal `settings.json`
(that file holds machine-specific profile GUIDs and lives under a package path that varies per
machine). Instead it surgically adds two idempotent blocks to whatever local `settings.json`
exists — a `sendInput` action emitting `\u001b\r` (ESC+CR, which Claude Code reads as a newline)
and a `shift+enter` keybinding mapped to it. Re-running is a no-op once present; the original
file is backed up to `.backups\terminal\` before any change. `deploy.ps1` invokes it
automatically, so `/sync-config pull` applies it on every machine.

## Skills

A skill is a directory under `global/skills/`, deployed to `~/.claude/skills/`. The directory
name becomes the slash command; `SKILL.md` holds the instructions. Because the whole directory
syncs, a skill can carry the scripts, templates and reference files its instructions rely on.

Give every skill a `description`. It is what Claude reads to decide whether a skill applies to
what you just asked for, and when it is missing the listing falls back to the first paragraph of
the file — so a skill that opens with a title heading advertises itself as that title and nothing
more. Write the description in the words you would actually use to ask for it, put the main use
case first, and keep it under 1,536 characters. `doctor.ps1` fails on a skill without one.

Keep frontmatter to the six fields the [Agent Skills spec](https://agentskills.io) allows:
`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. Claude Code
accepts several more, but uploading a skill to claude.ai — the route by which a personal skill
reaches Cowork and cloud sessions — rejects anything outside the spec with a hard error rather
than ignoring it. Note that neither `~/.claude/skills/` nor `~/.claude/commands/` is read by
those sessions at all; they load the skills enabled for your claude.ai account.

Files in `.claude/commands/` still work and still produce a slash command, so an older layout
keeps running. If you are upgrading from one, the first `/sync-config pull` after this change
deletes the `~/.claude/commands/*.md` files this repo previously deployed and installs the skill
directories in their place. That deletion is bounded by `.deployed-manifest.json`, so commands
you wrote yourself stay where they are, and everything removed is backed up first.

## Two CLAUDE.md files

`global/CLAUDE.md` deploys to `~/.claude/CLAUDE.md` and holds what is true wherever you start a
session. `project-desktop/CLAUDE.md` deploys to `<Desktop>\CLAUDE.md` and holds only what is true
of the Desktop. Claude reads the first in every session and the second only when the session
starts there, so a user-level fact kept in the project file is a fact that quietly goes missing
whenever you work somewhere else.

Keep procedures out of both. A section that has become a sequence of steps belongs in a skill,
where it costs no context until something actually calls for it.

## Dynamic Workflows

[Dynamic workflows](https://docs.claude.com/en/docs/claude-code/) are `*.js` scripts under
`<Desktop>\.claude\workflows\` that orchestrate multiple subagents deterministically.
They are synced as a unit (every `*.js` file in that folder), the same way agents and slash
commands are. The included `deep-research-tiered.js` is a sample: the session model decomposes the
question into search angles and key assertions, worker-model agents fan out to search and fetch
sources, each extracted claim gets a fast Haiku scan that escalates doubtful or key-assertion
claims to two Sonnet adversarial-lens votes, and the session model synthesizes a cited report and
runs a completeness critique against the key assertions. Every spawned agent uses the lightweight
`research-worker` agent definition (`global/agents/research-worker.md`) — a barebones system
prompt with no MCP tools or skills.

`enableWorkflows` ships as `false` in `global/settings.json`, to keep the Workflow tool's large
schema out of context in ordinary sessions. The `/deep-research-tiered` skill turns it on, runs
the workflow, and turns it back off; the setting hot-reloads on every request, so no restart is
involved. To start a session with workflows already enabled instead, pass
`--settings "$env:USERPROFILE\.claude\workflows-on.json"` — a one-key file that overrides nothing
else.

Because workflow scripts hold no machine-specific paths, they are copied verbatim (the username
placeholder pass is a no-op on them).

## Adding New Files to Sync

To add a new **skill**, create `global/skills/<name>/SKILL.md`. For a new **agent**, a `.md` file
in `global/agents/`. For a new **workflow**, a `.js` file in
`project-desktop/.claude/workflows/`. For a new **secret**, add a `{name, purpose}` entry to
`secrets.json`; `deploy.ps1` and `doctor.ps1` then report on it automatically.

To sync something the repo does not already handle, add one entry to `Get-SyncPlan` in
`lib/Common.ps1` — `Files` for an individual file, `Dirs` for a whole folder with a `Filter`
(e.g. `*.md` or `*.js`) and a `Recurse` flag for folders with subdirectories, as skills have.
That single list is what `collect.ps1`, `deploy.ps1` and `doctor.ps1` all read, so one entry
teaches all three. Each of them enumerates a folder through `Get-PlanFiles`, which identifies a
file by its path relative to the folder root rather than by its name — which is what lets every
skill call its file `SKILL.md` without them colliding.

Folders sync as a unit in both directions: a file deleted locally leaves the repo on the next
collect, and a file deleted from the repo is pruned locally on the next deploy (after a backup).

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
- **What gets synced is declared once.** `collect.ps1` (local → repo), `deploy.ps1` (repo →
  local) and `doctor.ps1` ("did it actually arrive, and does it still match?") all need the same
  list, and it used to be written out three times. Two copies drifting is a bug you notice; the
  third was doctor's, where a missing entry is invisible — doctor simply stops checking that
  file and keeps printing green. The list now lives in `Get-SyncPlan`.
