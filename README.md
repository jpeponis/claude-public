# Claude Code Portable Configuration

A template for syncing agent configuration — Claude Code settings, launchers, agents, skills,
a statusline, dynamic workflows, and a Codex CLI target — across multiple Windows machines. It
installs in one command, checks its own work, refuses to overwrite one machine's work with
another's, and can put back anything a deploy changed. This is the public version of a personal
setup — feel free to fork, adapt, and add your own skills, agents, and workflows.

Two scope notes up front:

- **Windows-to-Windows only, by design.** Secrets are DPAPI-encrypted, the launchers are
  PowerShell, and paths are resolved through Windows folder APIs. None of it travels to
  macOS/Linux.
- **The Codex target means "Codex CLI launched through `codex-sp`".** Codex profiles are
  CLI-flag-only (verified on 0.149.0: a `profile` key in `config.toml` is rejected as legacy),
  so direct `codex` launches, the IDE extension, and the desktop app never see the synced
  profile.

## Repository Structure

- `global/` — The Claude Code user target, deployed to `%USERPROFILE%\.claude\`
  - `settings.json` — Global settings, permissions, model, and statusline registration
  - `workflows-on.json` — A one-key settings overlay (`{ "enableWorkflows": true }`) for
    `claude --settings`; see *Dynamic Workflows*
  - `CLAUDE.md` — User-level instructions: what holds wherever you start a session. Also the
    *source* of the generated Codex instructions (see below)
  - `statusline-command.ps1` — Statusline showing user@machine, directory and git branch,
    subscription usage for the current five-hour window, and context-window fullness
  - `agents/` — Authored agent definitions (file-manager, for bulk file operations that would
    otherwise eat the main context). `directed.md` and `research-worker.md` also land in
    `~/.claude/agents/`, but they are **generated** — see `directed-agent/` below
  - `refresh-directed-agent.ps1` — Rebuilds the generated agents in `~/.claude/agents/` from
    `System Prompt.txt` plus the head fragments whenever either changed. Two callers:
    `claude-sp` / `claude-or` run it before launching (exact), and a SessionStart hook in
    `settings.json` runs it for sessions started any other way — one build late for those,
    since Claude Code reads agent files before its SessionStart hooks fire. Silent on
    success, because a SessionStart hook's stdout is injected into the model's context
  - `skills/<name>/SKILL.md` — Claude-only skills, one directory each (sync-config,
    deep-research-tiered)
- `directed-agent/` — The `directed` subagent: `System Prompt.txt` wearing agent frontmatter,
  so a delegated worker runs under the same rules as the session that spawned it rather than
  the built-in general-purpose prompt (a subagent's file body *replaces* that prompt)
  - `directed.head.md` / `research-worker.head.md` — The frontmatter (name, description,
    tools, model) plus a one-line role note, one per agent. Edit these. research-worker is
    the minimal-context worker used by deep-research-tiered: the same prompt behind a
    restricted tool list
  - `directed.md` / `research-worker.md` — **Generated; never edit.** `collect.ps1` rebuilds
    them, `doctor.ps1` fails when they are stale, and they are excluded from collection so a
    deployed copy is never adopted as if it had been authored in `~/.claude/agents/`
- `shared/skills/` — Skills both products consume, deployed to **both** `~/.claude/skills/`
  and `~/.agents/skills/`. Empty in the public repo; the mechanism is what ships
- `codex/` — The Codex CLI target
  - `personal.config.toml` — Portable Codex preferences (a template here), selected by
    `codex-sp` via `--profile personal` and deployed to `~/.codex/`
  - `AGENTS.md`, `project-desktop/AGENTS.md` — **Generated; never edit.** Built from the
    matching `CLAUDE.md` minus its `<!-- claude-only -->` blocks. `collect.ps1` rebuilds them;
    `doctor.ps1` fails when they are stale
  - `agents/research_worker.toml` — Codex custom agent, the counterpart of
    `research-worker.md`
  - `skills/` — Codex-only skills, deployed to `~/.agents/skills/` (none ship)
- `project-desktop/` — Maps to your Desktop. Resolved with
  `[Environment]::GetFolderPath('Desktop')` rather than `%USERPROFILE%\Desktop`, so it still
  lands in the right place when OneDrive Known Folder Move has redirected Desktop — the
  default on a consumer Windows 11 setup
  - `CLAUDE.md` — Instructions scoped to the Desktop itself
  - `.claude/settings.local.json` — Project-local settings
  - `.claude/workflows/` — Dynamic workflow scripts (`*.js`, e.g. deep-research-tiered)
- `powershell/claude-functions.ps1` — Deployed to `~/.claude/`. Defines `claude-sp`,
  `claude-spsp`, and the `claude-or*` launchers. `powershell/codex-functions.ps1` — deployed
  to `~/.codex/`, defines `codex-sp`. They are separate files under separate roots on purpose:
  the Codex target works without the Claude target installed. Both profiles dot-source both
  files through one managed block, and each file finds the repo through a machine-local
  `.config-root` pointer `deploy.ps1` writes beside it — no hardcoded install path
- `bootstrap.ps1` — One-command install: forks, clones, deploys, verifies (public-repo native)
- `collect.ps1` — Local config → repo (parameterizes the username; refuses on multi-machine
  divergence, `-Force` overrides; rebuilds the generated files)
- `deploy.ps1` — Repo → local machine (resolves the username; rolls itself back if any write
  fails; announces when it adopts a file it never managed before)
- `sync-config.ps1` — `push` / `pull` wrapper around the two above
- `doctor.ps1` — Report what actually works on this machine; exits non-zero if anything failed
- `restore.ps1` — Restore from the timestamped backups `deploy.ps1` writes to `.backups\`
- `compat.json` — The oldest Codex version the Codex checks hold on; `doctor.ps1` fails below
  it. There is no ceiling (see *Version floor* under the Codex target)
- `tests/run-tests.ps1` — Unit tests for the sync engine's branching logic. Deliberately
  dependency-free (plain asserts): a suite that needs installing before it runs is a suite
  that does not run
- `Set-Secret.ps1` / `Get-Secret.ps1` — Per-machine encrypted secret store (repo-native).
  Secrets are DPAPI-encrypted to `%USERPROFILE%\.claude\.<name>.enc` (current user, current
  machine only) and are never collected or deployed; `deploy.ps1` warns about missing ones
- `secrets.json` — Registry of which secrets exist and what each one unlocks. An entry with a
  `plugin` field is expected only while that Claude Code plugin is enabled
- `lib/Common.ps1` — Shared helpers: the artifact manifest (what syncs, declared once and read
  by collect, deploy and doctor), token substitution in both directions, the
  derived-instructions build, file enumeration, profile discovery, managed-block injection,
  backup enumeration, JSON validation
- `System Prompt.txt` — Custom system prompt (repo-native, not collected/deployed). Used two
  ways: `claude-sp` passes it as the session's system prompt, and the agents in
  `directed-agent/` are generated from it, so an edit reaches both the session and every
  `directed` subagent on the next `claude-sp` launch
- `apply-terminal-keybinding.ps1` — Repo-native; injects a Shift+Enter→newline action into the
  local Windows Terminal `settings.json`. Run automatically at the end of `deploy.ps1`

The scripts run from the repo; `global/`, `shared/`, `codex/` and `project-desktop/` are what
gets deployed.

## The Artifact Manifest

What syncs is declared once, in `Get-ArtifactManifest` (`lib/Common.ps1`), and read by
`collect.ps1`, `deploy.ps1` and `doctor.ps1`. That single list matters beyond tidiness: a
mapping missing from *doctor's* copy is invisible — doctor simply stops checking that file and
keeps printing green.

Each artifact declares more than a path pair:

- **Authority.** `installed` artifacts treat the deployed tree as the truth: collect reads
  them back from exactly one place (`CollectFrom`). `repository` artifacts are never
  collected — the generated `AGENTS.md` files are *built* from their sources instead, so
  editing one in place is an error doctor reports, not a change the sync adopts.
- **Destinations.** An artifact can deploy to several places. A shared skill lands in both
  `~/.claude/skills/` and `~/.agents/skills/`; the second copy is a projection — deploy
  refreshes it, collect ignores it, and there is never a question of which copy wins.
- **Membership.** Two skill sets share the same destination directory, so membership rules
  keep them apart: which skills are *shared* is decided by where they sit in the repo tree,
  the Claude-only set excludes the shared members, and `Test-ArtifactManifest` refuses any
  manifest where two artifacts claim the same skill. Files the manifest does not own — your
  own local skills, another tool's — are reported and left alone, never pruned.

## Divergence Is Refused, Not Absorbed

`push` runs pull → collect → commit. On a machine whose deployed tree is stale, that used to
be silent data loss: the pull brings down another machine's newer files, and collect
immediately overwrites them with this machine's old copies — git sees a clean, plausible
commit, not a conflict.

So `deploy.ps1` records the commit it deployed in `.last-deployed` (machine-local, untracked),
and `collect.ps1` refuses to run when a managed artifact changed between that commit and HEAD
*while also* disagreeing with the installed copy — and names the artifacts. The fix it
prescribes is `deploy.ps1` (take the repo's newer version; yours is backed up first), because
that is almost always right; `collect.ps1 -Force` is the deliberate override for when this
machine's copy should win. `sync-config.ps1 push` stops on the refusal rather than rolling on
to a green "Nothing to commit".

Deploy is transactional against the same backups: if any write fails, every file that run
already wrote is put back (or removed, if it did not exist before), and the failure is
rethrown — no half-updated machine.

## The Codex Target

`codex-sp` launches Codex CLI with two things layered on: the `personal` profile
(`~/.codex/personal.config.toml`, deployed from this repo) and a `model_instructions_file`
override pointing at `System Prompt.txt`.

Know what you are opting into:

- **Prompt replacement is explicitly discouraged upstream.** The Codex config schema says
  users are "STRONGLY DISCOURAGED" from overriding the built-in instructions. `codex-sp` is
  the experimental variant; plain `codex` is the control. When behavior looks off, compare
  against the control before blaming the task.
- **The generated `AGENTS.md` files are how Codex learns your machine's rules.** Codex reads
  `~/.codex/AGENTS.md` (global) the way Claude reads `~/.claude/CLAUDE.md` — and rather than
  maintaining two copies of the same facts, this repo *derives* the Codex files from the
  CLAUDE.md ones. Wrap Claude-specific sections in `<!-- claude-only -->` …
  `<!-- /claude-only -->`; unmarked content is shared and should stay host-neutral (name
  capabilities, not proprietary tool names). `doctor.ps1` fails on stale outputs and warns
  when Claude-only vocabulary leaks past the markers.
- **Discovery caveat.** Codex reads a Desktop `AGENTS.md` only when the working root *is* the
  Desktop or a non-repository child — sessions inside a git repo start discovery at that
  repo's root and never look above it. Repo-specific Codex instructions belong in each repo's
  own root `AGENTS.md`.
- **Version floor.** The surfaces this leans on (file profiles, prompt replacement, agent TOML)
  are version-sensitive, and the published schema has already been caught documenting a key
  the binary rejects. `compat.json` records the minimum version; `doctor.ps1` fails below it.
  There is deliberately no "newest certified" ceiling: Codex ships every few days, so a pin
  is stale within the week and its warning is permanently on — and a warning that is always
  on is one nobody reads. The per-version verification is doctor's probe (`codex -p personal
  debug prompt-input`), which runs every time: it validates the profile and verifies the
  deployed `AGENTS.md` still reaches the model's input under the profile — the coexistence
  you are relying on is a behavior of the installed version, not a documented contract, so
  it is re-checked rather than assumed.

Codex machine state — `auth.json`, the base `config.toml`, databases, trust records — never
syncs, and doctor fails if any of it is ever tracked.

## How Path Portability Works

Config files contain absolute Windows paths, and they differ on every machine. Three tokens
stand in for the parts that vary. `collect.ps1` writes them when it pulls config into the
repo, and `deploy.ps1` expands them on the way back out:

| Token | Expands to |
| --- | --- |
| `{{USERNAME}}` | your Windows account name |
| `{{DESKTOP}}` | your real Desktop, forward-slashed |
| `{{CONFIG_ROOT}}` | this repo's absolute path, forward-slashed |

Collect matches case-insensitively and accepts either slash direction, since a path on disk
may be spelled differently than `%USERNAME%` reports it. Deploy substitutes literally, in
forward-slash form, which both PowerShell and Git Bash accept.

The username token is **path-only**, in both directions. Collect replaces the account name
only where it is the path segment after `Users\` or `Users/` (the JSON-escaped `Users\\` too),
and deploy expands `{{USERNAME}}` only in that position. Anywhere else the same string is
somebody's identity — a GitHub handle, an email address, a person's name in prose — and it is
never rewritten, so it cannot turn into the next machine's account name on the way back out.
Afterwards `collect.ps1` fails if any file still holds a path-shaped occurrence of the account
name it could not tokenize (a `C:\Users\<name>.old\`, say), and `doctor.ps1` fails if synced
markdown spells out a literal `Desktop\claude-config` or `Desktop\claude-scratch` path (either
slash direction).

Markdown needs the tokens as much as JSON does. A skill telling the model to run
`$HOME/Desktop/claude-config/something.ps1` is wrong on any machine where OneDrive Known
Folder Move has redirected Desktop — the instructions are executed, so a path in prose is as
real as a path in a settings file.

One key is deliberately excluded from collection: `model` in `global/settings.json`. It
records whichever model the last session happened to be using, so collecting it would let one
machine's passing choice change the model on another at the next pull. The repo's value is the
default; edit the file to change it.

## First-Time Setup on a New Machine

### Prerequisites
- Windows
- [Git](https://git-scm.com/) installed and configured with GitHub credentials
- [GitHub CLI](https://cli.github.com/), authenticated with `gh auth login` (used to fork)
- Claude Code, from the native installer (`irm https://claude.ai/install.ps1 | iex`) or
  `winget install Anthropic.ClaudeCode` (WinGet installs do not auto-update). npm
  (`npm install -g @anthropic-ai/claude-code`) is the advanced option: it needs Node.js 22+ to
  install, but what it installs is the same native binary, which does not use Node at runtime
- Optional: Codex CLI (`npm install -g @openai/codex`) — without it, doctor simply reports the
  Codex target unchecked. This is what [Node.js](https://nodejs.org/) is for: npm-installed
  tools like Codex need it, and nothing else here does

`bootstrap.ps1` checks git and gh and stops with the exact command to fix either, rather than
half-installing. A missing Claude Code is only a warning (installing the config first is a
legitimate order to do things in), and a missing Node is just reported.

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

   Either web form runs inside your current PowerShell session, so the script never calls
   `exit` there — that would close the session, and the Terminal tab with the output in it. It
   leaves its exit code in `$LASTEXITCODE` instead.

   One more step appears in the plan on most fresh machines. The launchers load from your
   PowerShell profile, and Windows PowerShell 5.1's default execution policy on Windows 11,
   `Restricted`, never runs a profile at all (PowerShell 7 defaults to `RemoteSigned` and needs
   nothing). So when bootstrap finds 5.1's effective policy `Restricted` or `AllSigned`, it adds
   *Set Windows PowerShell's CurrentUser execution policy to RemoteSigned* to the plan, and
   does it after you confirm. If Group Policy sets the policy, nothing a user can set overrides
   it; bootstrap says so and installs anyway, and the launchers then load only in PowerShell 7.

   The fork is the default rather than an afterthought. `sync-config push` pushes to
   `origin`, so a plain clone of someone else's repo is a setup whose push half is broken from
   the first day.

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

   If Codex CLI is installed, `codex-sp` should likewise start a session carrying the custom
   prompt and the generated `~/.codex/AGENTS.md`.

### Installing by Hand

Clone the repo (fork it first if you want `/sync-config push` to work), then deploy and
verify:

```powershell
$repo = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config'
git clone https://github.com/<you>/claude-public.git $repo
cd $repo
git remote add upstream https://github.com/jpeponis/claude-public.git
powershell -ExecutionPolicy Bypass -File deploy.ps1
powershell -ExecutionPolicy Bypass -File doctor.ps1
```

(`GetFolderPath` rather than `$env:USERPROFILE\Desktop`, because OneDrive Known Folder Move
can redirect the Desktop, leaving the literal path missing or stale. Deploy resolves the true
Desktop itself; `$repo` is only where the repo lives, and `deploy.ps1` writes `.config-root`
pointers so the launchers find it wherever you put it. The `upstream` remote is what
`git pull upstream main` uses later; bootstrap adds it for you.)

If doctor reports Windows PowerShell's execution policy as `Restricted` or `AllSigned`, your
profile — and with it every launcher — never loads there. Fix it in Windows PowerShell with
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, which is the step bootstrap would have
taken for you.

### Optional: GitHub MCP plugin

The GitHub MCP plugin (`github@claude-plugins-official`) ships **off**, and most people can
leave it that way: bootstrap already requires `gh auth login`, and Claude can do most GitHub
work through `gh` without the plugin. To use it anyway:

1. Turn it on: set `"github@claude-plugins-official"` to `true` under `enabledPlugins` in
   `~/.claude/settings.json` — the deployed copy, as with any setting — then push
   (`/sync-config push`), so your other machines get it too.
2. Create a fine-grained token at https://github.com/settings/tokens?type=beta: name it
   something like "Claude Code", set an expiration if you want one, choose "All repositories"
   (or specific ones) under "Repository access", and under "Permissions" grant **Contents**,
   **Issues** and **Pull requests** read and write (**Metadata** read-only is selected
   automatically).
3. Store it in the encrypted secret store:
   ```powershell
   cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
   .\Set-Secret.ps1 -Name github-token
   ```
   The prompt hides the input and DPAPI-encrypts the token to `~/.claude/.github-token.enc`,
   readable only by your Windows account on that machine.

Nothing is decrypted at shell start. The launchers — `claude-sp`, `claude-or` and their
variants — load the token into the environment only for a session where the plugin is
enabled in `~/.claude/settings.json` and the secret exists, and remove it again when the
session ends; a `GITHUB_PERSONAL_ACCESS_TOKEN` you set yourself is left alone. A session
started with plain `claude` does not get the token. The plaintext never lands in your
registry, your shell history, or a file. `deploy.ps1` and `doctor.ps1` mention the secret
only while the plugin is on.

Setting `GITHUB_PERSONAL_ACCESS_TOKEN` as a plain user environment variable instead stores the
token in the registry in clear text, where every process you start inherits it — and the
launchers only read the encrypted store when the variable is unset, so doing both silently
gives you the weaker of the two.

## Launchers

`claude-sp` is the main launch command: Claude Code with the system prompt from
`System Prompt.txt` and permissions in auto mode. `claude-spsp` is the same thing plus
`--dangerously-skip-permissions`, which stops it asking before it acts — worth watching
`claude-sp` work for a while first, so you know what you are agreeing to in advance.

`codex-sp` is the Codex counterpart, described above. It lives in its own file under
`~/.codex/`, so the Codex target does not depend on the Claude one.

**On cost:** the shipped settings are Opus at `xhigh` effort. I recommend trying that to then
judge whether a cheaper or more expensive model will be good enough for your work.

## Ongoing Usage

One command moves your configuration between machines. Synced: `global/settings.json` and its
`workflows-on.json` overlay, skills (all three sets), agents (both formats), the statusline,
both shell-function files, both `CLAUDE.md` files and both generated `AGENTS.md` files, the
Codex profile, project-local settings, and workflow scripts. Not synced: the encrypted secrets and Codex machine state,
which are per-machine by construction, and your PowerShell profile — the functions live in
their own files that the profile sources, so nothing else in the profile is touched.

### From within Claude Code
Use the `/sync-config` slash command:
- `/sync-config pull` — Pull latest config from repo, deploy locally, then run `doctor.ps1`
- `/sync-config push` — Collect local config, commit, and push to repo

### From PowerShell

```powershell
cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
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

Push works because you forked; pushing to a repo you do not own does not. To take later
changes from upstream:

```powershell
git -C (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config') pull upstream main
```

**Which copy do you edit?** For `installed` artifacts (almost everything): the deployed copy —
`~/.claude/CLAUDE.md`, `~/.claude/skills/<name>/SKILL.md` — then push. For shared skills:
the `~/.claude` copy specifically; the `~/.agents` one is a projection. For the generated
`AGENTS.md` files: never — edit the CLAUDE.md sources and let collect rebuild them. If push
refuses with a divergence warning, read it: another machine's newer work is sitting in the
repo, and `deploy.ps1` is almost always the right answer.

### Optional: OpenRouter Key

Only needed for OpenRouter mode. Store it the same way as the GitHub token above:

```powershell
cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
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
cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
.\doctor.ps1
```

`doctor.ps1` reports what is actually true on this machine:

- Claude Code on PATH, and the Codex version against the `compat.json` floor. Node is only
  reported, since only npm-installed tools such as Codex need it
- Claude Code's settings files parsing as *strict* JSON: comments and trailing commas fail,
  because Claude Code rejects them even where Windows Terminal's JSONC would not
- every artifact the repo ships present at *every* destination — each skill, agent and
  workflow, and each single file (settings, memory files, launchers, generated agents and
  `AGENTS.md`) — and every deployed file still *matching* the repo
- the statusline actually executing
- both PowerShell profiles carrying the managed block with exactly the contents deploy writes,
  and no launcher code or secret reads left *outside* it from an older setup
- an execution policy that lets each wired profile run (the Process scope ignored, since it
  describes how doctor was started, not the next terminal you open), and Windows Terminal's
  default profile being one of those PowerShells
- the repo pointers pointing home, the Codex profile loading, and the deployed `AGENTS.md`
  reaching Codex's prompt input
- the generated files fresh, and free of Claude-only vocabulary — including the slash
  commands of Claude-only skills — and no Codex machine state tracked
- secrets that actually decrypt, counting only those that apply: the GitHub token is not
  asked for while its plugin is off

Each failure prints the command that fixes it, and the script exits non-zero if anything
failed. `/sync-config pull` runs it automatically and passes its exit code through.

It exists because `deploy.ps1` can only report what it *wrote*, which can be entirely true
while the outcome is still wrong — a file written perfectly to a location nothing reads is the
motivating case.

The match check earns its place for a quieter reason: editing `~/.claude/skills/foo/SKILL.md`
directly is a perfectly normal way to work on a skill, and nothing otherwise tells you the
repo now disagrees — until a later deploy overwrites the edit. It warns rather than fails,
because either direction can be the right one: `collect.ps1` keeps the local version,
`deploy.ps1` takes the repo's.

A final section checks the content rather than the plumbing: that every skill declares a
`description`, and that no synced markdown spells out a literal `Desktop\claude-config` or
`Desktop\claude-scratch` path (either slash direction; other Desktop paths are not matched).
These are the kind of mistake every other check passes straight over. (`research-worker.md` used to be checked
here against `System Prompt.txt`, which it duplicated by hand; it is now generated from it,
so the generated-file staleness check covers it.)

The unit tests cover the half of the engine doctor cannot: manifest validation, membership
filtering, divergence candidacy, token round trips, and the derived-instructions build:

```powershell
cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

To see what a deploy would change without changing anything:

```powershell
cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
.\deploy.ps1 -DryRun
```

It prints every write, deletion, adoption, profile edit and environment change, and performs
none of them.

```powershell
cd (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config')
.\restore.ps1                 # list what can be restored
.\restore.ps1 -Latest -DryRun # preview
.\restore.ps1 -Latest         # put it back
```

Every deploy first backs up the files it is about to overwrite into `.backups\<timestamp>\`,
with a manifest recording where each file came from, so `restore.ps1` puts files back exactly
there instead of inferring it. Only files whose content actually changes are copied, so a
deploy that changes nothing creates no backup directory at all and the newest 20 directories
it keeps are 20 real changes rather than 20 runs. Pass `-KeepBackups <n>` to change how many
are kept. A deploy that fails mid-run restores from the same backups automatically.

`deploy.ps1` is additive by design. It adds a small marked block to your PowerShell profiles
rather than replacing them, it announces (and backs up) any existing file it is about to
manage for the first time, and it only ever deletes files it previously deployed itself
(tracked in `~/.claude/.deployed-manifest.json`), so skills and agents you write yourself are
never touched.

## Windows Terminal Shift+Enter

`apply-terminal-keybinding.ps1` makes **Shift+Enter** insert a newline (instead of submitting)
in Claude Code under Windows Terminal. It does *not* sync the whole Terminal `settings.json`
(that file holds machine-specific profile GUIDs and lives under a package path that varies per
machine). Instead it surgically adds two idempotent blocks to whatever local `settings.json`
exists — a `sendInput` action emitting `\u001b\r` (ESC+CR, which Claude Code reads as a
newline) and a `shift+enter` keybinding mapped to it. Re-running is a no-op once present; the
original file is backed up to `.backups\terminal\` before any change. `deploy.ps1` invokes it
automatically, so `/sync-config pull` applies it on every machine.

## Skills

A skill is a directory whose name becomes the slash command; `SKILL.md` holds the
instructions. Because the whole directory syncs, a skill can carry the scripts, templates and
reference files its instructions rely on. Three sets exist:

- `global/skills/` — Claude-only, deployed to `~/.claude/skills/`
- `shared/skills/` — both products, deployed to `~/.claude/skills/` *and*
  `~/.agents/skills/`, collected from the `~/.claude` copy
- `codex/skills/` — Codex-only, deployed to `~/.agents/skills/`

A shared skill's instructions must stay host-neutral: name capabilities rather than
proprietary tool names, and bundle helper scripts inside the skill directory, invoked relative
to it — a skill whose scripts live in some unsynced scratch directory is not portable, however
portable its prose sounds.

Give every skill a `description`. It is what the model reads to decide whether a skill applies
to what you just asked for, and when it is missing the listing falls back to the first
paragraph of the file — so a skill that opens with a title heading advertises itself as that
title and nothing more. Write the description in the words you would actually use to ask for
it, put the main use case first, and keep it under 1,536 characters. `doctor.ps1` fails on a
skill without one.

Keep frontmatter to the six fields the [Agent Skills spec](https://agentskills.io) allows:
`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. Claude Code
accepts several more, but uploading a skill to claude.ai — the route by which a personal skill
reaches Cowork and cloud sessions — rejects anything outside the spec with a hard error rather
than ignoring it. Codex builds on the same open standard, which is what makes the shared set
possible at all. Note that neither `~/.claude/skills/` nor `~/.claude/commands/` is read by
claude.ai sessions; they load the skills enabled for your account.

## Instruction Files: Authored Twice, Written Once

`global/CLAUDE.md` deploys to `~/.claude/CLAUDE.md` and holds what is true wherever you start
a session. `project-desktop/CLAUDE.md` deploys to `<Desktop>\CLAUDE.md` and holds only what is
true of the Desktop. Claude reads the first in every session and the second only when the
session starts there, so a user-level fact kept in the project file is a fact that quietly
goes missing whenever you work somewhere else.

The Codex `AGENTS.md` files are **derived from them**, not authored beside them — two
hand-maintained copies of the same facts is drift by design. Mark Claude-specific sections:

```markdown
<!-- claude-only -->
## Something only Claude Code needs to know
<!-- /claude-only -->
```

Unmarked content flows into the generated files, so keep it host-neutral. The build refuses
unbalanced or nested markers outright — a generated instructions file that is silently wrong
is worse than a failed build.

Keep procedures out of all of them. A section that has become a sequence of steps belongs in a
skill, where it costs no context until something actually calls for it.

## Dynamic Workflows

[Dynamic workflows](https://docs.claude.com/en/docs/claude-code/) are `*.js` scripts under
`<Desktop>\.claude\workflows\` that orchestrate multiple subagents deterministically. They are
synced as a unit (every `*.js` file in that folder), the same way agents and skills are. The
included `deep-research-tiered.js` is a sample: the session model decomposes the question into
search angles and key assertions, worker-model agents fan out to search and fetch sources,
each extracted claim gets a fast Haiku scan that escalates doubtful or key-assertion claims to
two Sonnet adversarial-lens votes, and the session model synthesizes a cited report and runs a
completeness critique against the key assertions. Every spawned agent uses the lightweight
`research-worker` agent definition (generated into `directed-agent/research-worker.md`) — the
system prompt behind a restricted tool list, with no MCP tools or skills.

`enableWorkflows` ships as `false` in `global/settings.json`, to keep the Workflow tool's
large schema out of context in ordinary sessions. The `/deep-research-tiered` skill turns it
on, runs the workflow, and turns it back off; the setting hot-reloads on every request, so no
restart is involved. To start a session with workflows already enabled instead, pass
`--settings "$env:USERPROFILE\.claude\workflows-on.json"`. That one-key file
(`{ "enableWorkflows": true }`, overriding nothing else) ships with the config: it lives in
`global/` and deploys to `~/.claude/` like any other file, so every machine has it after a
deploy or `/sync-config pull`.

Because workflow scripts hold no machine-specific paths, they are copied verbatim (the
username placeholder pass is a no-op on them).

## Adding New Files to Sync

To add a new **Claude skill**, create `global/skills/<name>/SKILL.md` (or drop it in
`~/.claude/skills/` and push). A **shared skill** goes in `shared/skills/<name>/` — the repo
location *is* the membership decision. A new **agent**: a `.md` file in `global/agents/`, or
a `.toml` in `codex/agents/` with `name`, `description` and `developer_instructions`. A new
**workflow**: a `.js` file in `project-desktop/.claude/workflows/`. A new **secret**: a
`{name, purpose}` entry in `secrets.json` (plus `plugin`, naming an `enabledPlugins` key, if
the secret is needed only while that plugin is on); `deploy.ps1` and `doctor.ps1` then report
on it automatically.

To sync something the repo does not already handle, add one artifact to
`Get-ArtifactManifest` in `lib/Common.ps1` — `Files` for an individual file, `Dirs` for a
whole folder with a `Filter` (e.g. `*.md` or `*.js`) and a `Recurse` flag. Declare its
authority and, for installed artifacts, the one destination collect reads from.
`Test-ArtifactManifest` will refuse anything internally inconsistent, and the unit tests show
the expected shapes. Folders sync as a unit in both directions: a file deleted locally leaves
the repo on the next collect, and a file deleted from the repo is pruned locally on the next
deploy (after a backup).

Then run `collect.ps1` and commit and push — or just `/sync-config push`, which does all
three.

## Implementation Notes

- **Both PowerShell editions are wired.** Windows PowerShell 5.1 and PowerShell 7 read
  different profile paths. `deploy.ps1` injects its managed block into both, so the functions
  exist in whichever shell you open. `doctor.ps1` checks each one, along with the execution
  policy that decides whether it runs at all, and warns when Windows Terminal's default
  profile is not one of them.
- **Repo `.ps1` files are pure ASCII, on purpose.** Windows PowerShell 5.1 reads a BOM-less
  file as ANSI, so a stray em-dash decodes into a smart quote that PowerShell treats as a
  string delimiter — fatal inside a double-quoted string. `doctor.ps1` enforces it. Markdown
  is fine.
- **Text files are LF everywhere.** `.gitattributes` pins it, and the generated files are
  built LF for the same reason: a CRLF-built output would compare "stale" against its own LF
  checkout on the next machine forever.
- **No hand-written CLI grammars.** An earlier `codex-sp` parsed Codex's subcommands to
  decide where a flag was legal, and went stale within one Codex release. The wrapper now
  passes only what it must; strict validation is doctor's job, once per version.
