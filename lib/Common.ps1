# lib/Common.ps1 -- Shared helpers, dot-sourced by collect.ps1, deploy.ps1, doctor.ps1,
# restore.ps1, publish.ps1 and apply-terminal-keybinding.ps1.
#
# Dot-source with:  . (Join-Path $repoRoot "lib\Common.ps1")
#
# Everything here is repo-native (never deployed to ~/.claude).

# --- UTF-8 without BOM: the encoding every file in this repo is written with ---
function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

# --- Reading one back: '' for an empty file, never $null ---------------------
# Get-Content -Raw returns $null for a 0-byte file, and $null -eq '' is false, so every
# empty file (a Python package's __init__.py) compared as changed on every deploy and
# drifted in every doctor run. A [string] cast does not rescue it -- the value stays
# null through the cast, in 5.1 and 7 alike. ReadAllText returns '' and, like
# Get-Content -Encoding UTF8, drops a UTF-8 BOM. Convert-Path because .NET resolves a
# relative path against the process directory, not the PowerShell location.
function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText((Convert-Path -LiteralPath $Path), [System.Text.Encoding]::UTF8)
}

# --- Desktop, resolved the same way Documents is -----------------------------
# "$env:USERPROFILE\Desktop" is wrong on any machine with OneDrive Known Folder Move
# enabled, which is the Windows 11 default on a consumer setup: the real Desktop is
# then "$env:USERPROFILE\OneDrive\Desktop" and the literal path either does not exist
# or is a stale leftover. deploy.ps1 puts CLAUDE.md and .claude\settings.local.json
# there, so getting this wrong writes project config to a directory the user never
# opens -- the same silent-success failure the profile paths had.
#
# bootstrap.ps1 deliberately repeats this logic inline rather than calling it: it runs
# before the repo exists, so it cannot dot-source this file.
function Get-DesktopPath {
    $d = [Environment]::GetFolderPath('Desktop')
    if ($d) { return $d }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

# --- What this repo syncs: ONE description, three consumers ------------------
# collect.ps1 (local -> repo), deploy.ps1 (repo -> local) and doctor.ps1 (is it
# actually there?) all need the same list. It used to be written out three times.
# Two copies drifting is a bug you notice; the third was doctor's, and a mapping
# missing from THAT one is invisible -- doctor simply stops checking a file and
# keeps printing green. So the list lives here, and adding a mapping teaches all
# three scripts at once.
#
# This is an ARTIFACT MANIFEST, not a pair list. The old model was flat repo<->local
# pairs consumed bidirectionally, which cannot express one source deployed to two
# destinations (a shared skill goes to BOTH ~/.claude/skills and ~/.agents/skills),
# nor a generated file that must never be collected back. Each artifact declares:
#
#   Id            unique name, used in errors and by ExcludeMembersOf
#   Repo          repo-relative source path (file, or directory root for Dirs)
#   Destinations  one or more absolute local paths deploy writes to
#   Authority     'installed'  -- the deployed tree is the truth; collect reads it
#                 'repository' -- the repo is the truth; collect NEVER touches it
#   CollectFrom   (installed only) exactly ONE destination collect reads from.
#                 For a multi-destination artifact the others are projections:
#                 deploy refreshes them, collect ignores them.
#   GeneratedFrom / GeneratedExtra / Builder
#                 (repository only) this file is BUILT from other repo files -- see
#                 Get-GeneratedArtifactContent. Builder picks the recipe: absent means
#                 Build-DerivedInstructions (a Codex AGENTS.md), 'agent' means
#                 Build-AgentDefinition (a Claude subagent whose body is the source and
#                 whose frontmatter is the GeneratedExtra fragment).
#   Filter/Recurse/Name   (Dirs only) same meaning as before.
#   MembersFromRepo       (Dirs) collect only top-level entries that already exist
#                 in the repo directory -- the repo decides membership. Used by
#                 shared skills: which skills are shared is a repo decision, so a
#                 new local-only skill lands in the claude-skills set, not here.
#   ExcludeMembersOf      (Dirs) skip local top-level entries owned by the named
#                 artifact(s); one id or a list. claude-skills excludes shared-skills'
#                 members so a shared skill is not collected into global\skills a
#                 second time; claude-agents excludes the generated agents (FILE
#                 artifacts, each owning just its own filename) so a generated agent
#                 deployed into ~/.claude/agents is not collected back as authored.
#   ForeignMembers        (Dirs) top-level entry names another program owns inside
#                 this artifact's destination. collect never reads them, and deploy
#                 never prunes them -- a file an earlier deploy wrote there is released
#                 from the deployed manifest, not deleted. claude-skills names 'synced',
#                 Claude Code's own cache of the skills it downloads from claude.ai.
#   Optional      (Dirs) doctor reports an empty repo set as OK, not a warning.
#
# Deliberately NOT in this manifest, each for a reason worth keeping:
#   - The PowerShell profile. Collecting a whole profile drags in unrelated shell
#     config and can only ever capture one of the two profile paths (5.1 vs 7+).
#     The functions live in claude-functions.ps1 / codex-functions.ps1; profiles
#     get a managed block that dot-sources both (see Add-ClaudeProfileBlock).
#   - ~/.claude/.*.enc secrets. DPAPI-bound to one user on one machine, so they
#     cannot travel. secrets.json registers the names; each machine runs Set-Secret.ps1.
#   - Repo-native scripts ("System Prompt.txt", lib\, and the launcher / doctor /
#     restore / publish scripts). They are run FROM the repo, not deployed.
#   - codex\AGENTS.extra.md and codex\project-desktop\AGENTS.extra.md: source
#     fragments for the generated AGENTS.md files, edited in the repo. Likewise
#     directed-agent\directed.head.md, the frontmatter fragment of the directed agent.
#   - ~/.codex machine state (auth.json, config.toml, databases, caches, trust
#     records, default.rules). Machine-generated, never synced.
#   - Codex rules: nothing portable exists yet. When one does, add a
#     codex\rules\portable.rules artifact rather than syncing default.rules.
#
# Two memory files, at two scopes, on purpose. ~/.claude/CLAUDE.md holds the facts
# that are true wherever a session is started; <Desktop>\CLAUDE.md holds only what is
# true of the Desktop itself. The Codex AGENTS.md files are DERIVED from them:
# shared sections pass through, <!-- claude-only --> blocks are stripped, and the
# AGENTS.extra.md fragment is appended. One source of shared facts, two outputs.
function Get-ArtifactManifest {
    param(
        [Parameter(Mandatory)][string]$ClaudeHome,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$AgentsHome,
        [Parameter(Mandatory)][string]$DesktopDir
    )
    @{
        Files = @(
            @{ Id = 'claude-settings';  Repo = 'global\settings.json';          Authority = 'installed'
               Destinations = @("$ClaudeHome\settings.json");          CollectFrom = "$ClaudeHome\settings.json" }
            @{ Id = 'claude-memory';    Repo = 'global\CLAUDE.md';              Authority = 'installed'
               Destinations = @("$ClaudeHome\CLAUDE.md");              CollectFrom = "$ClaudeHome\CLAUDE.md" }
            @{ Id = 'statusline';       Repo = 'global\statusline-command.ps1'; Authority = 'installed'
               Destinations = @("$ClaudeHome\statusline-command.ps1"); CollectFrom = "$ClaudeHome\statusline-command.ps1" }
            @{ Id = 'claude-functions'; Repo = 'powershell\claude-functions.ps1'; Authority = 'installed'
               Destinations = @("$ClaudeHome\claude-functions.ps1");   CollectFrom = "$ClaudeHome\claude-functions.ps1" }
            @{ Id = 'codex-functions';  Repo = 'powershell\codex-functions.ps1';  Authority = 'installed'
               Destinations = @("$CodexHome\codex-functions.ps1");     CollectFrom = "$CodexHome\codex-functions.ps1" }
            @{ Id = 'desktop-memory';   Repo = 'project-desktop\CLAUDE.md';     Authority = 'installed'
               Destinations = @("$DesktopDir\CLAUDE.md");              CollectFrom = "$DesktopDir\CLAUDE.md" }
            @{ Id = 'desktop-settings'; Repo = 'project-desktop\.claude\settings.local.json'; Authority = 'installed'
               Destinations = @("$DesktopDir\.claude\settings.local.json"); CollectFrom = "$DesktopDir\.claude\settings.local.json" }
            @{ Id = 'codex-profile';    Repo = 'codex\personal.config.toml';    Authority = 'installed'
               Destinations = @("$CodexHome\personal.config.toml");    CollectFrom = "$CodexHome\personal.config.toml" }
            @{ Id = 'codex-memory';     Repo = 'codex\AGENTS.md';               Authority = 'repository'
               Destinations = @("$CodexHome\AGENTS.md")
               GeneratedFrom = 'global\CLAUDE.md'; GeneratedExtra = 'codex\AGENTS.extra.md' }
            @{ Id = 'codex-desktop-memory'; Repo = 'codex\project-desktop\AGENTS.md'; Authority = 'repository'
               Destinations = @("$DesktopDir\AGENTS.md")
               GeneratedFrom = 'project-desktop\CLAUDE.md'; GeneratedExtra = 'codex\project-desktop\AGENTS.extra.md' }
            # The directed subagent is "System Prompt.txt" wearing agent frontmatter, so the
            # prompt a delegated worker runs under is the one the session runs under. Built,
            # not authored: a hand copy of the prompt (research-worker's body was one) drifts
            # the first time the prompt is edited. Lives outside global\agents so the
            # claude-agents dir artifact cannot collect it back; that artifact excludes it
            # by name instead. The deployed copy is also refreshed at every session start
            # by global\refresh-directed-agent.ps1 (a SessionStart hook in settings.json).
            @{ Id = 'directed-agent';   Repo = 'directed-agent\directed.md';    Authority = 'repository'
               Destinations = @("$ClaudeHome\agents\directed.md")
               GeneratedFrom = 'System Prompt.txt'; GeneratedExtra = 'directed-agent\directed.head.md'; Builder = 'agent' }
            # research-worker (deep-research-tiered's worker) is the same prompt behind a
            # restricted tool list. It was a hand copy, and doctor caught it five lines
            # adrift; now it is built from the same source, and can only differ in its head.
            @{ Id = 'research-worker-agent'; Repo = 'directed-agent\research-worker.md'; Authority = 'repository'
               Destinations = @("$ClaudeHome\agents\research-worker.md")
               GeneratedFrom = 'System Prompt.txt'; GeneratedExtra = 'directed-agent\research-worker.head.md'; Builder = 'agent' }
            @{ Id = 'directed-refresh'; Repo = 'global\refresh-directed-agent.ps1'; Authority = 'installed'
               Destinations = @("$ClaudeHome\refresh-directed-agent.ps1"); CollectFrom = "$ClaudeHome\refresh-directed-agent.ps1" }
        )
        # Every file matching Filter is synced as a unit, in both directions:
        # deleting one locally removes it from the repo on the next collect, and
        # deleting it from the repo prunes it locally on the next deploy.
        #
        # Recurse belongs to the skill entries because a skill is a DIRECTORY, not a
        # file: <skills>/<name>/SKILL.md plus whatever supporting files that skill
        # bundles. Filter is '*' there for the same reason -- restricting it to
        # '*.md' would sync a skill's instructions while silently leaving behind the
        # scripts those instructions tell Claude to run.
        Dirs = @(
            @{ Id = 'shared-skills'; Name = 'shared skills'; Repo = 'shared\skills'; Authority = 'installed'
               Destinations = @("$ClaudeHome\skills", "$AgentsHome\skills"); CollectFrom = "$ClaudeHome\skills"
               Filter = '*'; Recurse = $true; MembersFromRepo = $true; Optional = $true }
            # 'synced' is Claude Code's cache of claude.ai skills (docs, docx, pdf, ...),
            # rewritten by Claude Code itself. Collected once by accident (2026-09-19):
            # 217 files, no SKILL.md, and a deploy fighting the program that owns them.
            @{ Id = 'claude-skills'; Name = 'claude skills'; Repo = 'global\skills'; Authority = 'installed'
               Destinations = @("$ClaudeHome\skills"); CollectFrom = "$ClaudeHome\skills"
               Filter = '*'; Recurse = $true; ExcludeMembersOf = 'shared-skills'; ForeignMembers = @('synced') }
            @{ Id = 'codex-skills'; Name = 'codex-only skills'; Repo = 'codex\skills'; Authority = 'installed'
               Destinations = @("$AgentsHome\skills"); CollectFrom = "$AgentsHome\skills"
               Filter = '*'; Recurse = $true; ExcludeMembersOf = 'shared-skills'; Optional = $true }
            @{ Id = 'claude-agents'; Name = 'claude agents'; Repo = 'global\agents'; Authority = 'installed'
               Destinations = @("$ClaudeHome\agents"); CollectFrom = "$ClaudeHome\agents"
               Filter = '*.md'; Recurse = $false; ExcludeMembersOf = @('directed-agent', 'research-worker-agent') }
            @{ Id = 'codex-agents'; Name = 'codex agents'; Repo = 'codex\agents'; Authority = 'installed'
               Destinations = @("$CodexHome\agents"); CollectFrom = "$CodexHome\agents"
               Filter = '*.toml'; Recurse = $false; Optional = $true }
            @{ Id = 'workflows'; Name = 'workflows'; Repo = 'project-desktop\.claude\workflows'; Authority = 'installed'
               Destinations = @("$DesktopDir\.claude\workflows"); CollectFrom = "$DesktopDir\.claude\workflows"
               Filter = '*.js'; Recurse = $false }
        )
    }
}

# Validate the manifest's internal consistency, throwing on the first defect. Runs at
# the top of collect and deploy so a bad edit to the manifest is a refusal, not a
# half-applied sync. With -RepoRoot it also checks that no two dir artifacts sharing
# a destination claim the same top-level member -- the collision that would make
# collection ambiguous.
function Test-ArtifactManifest {
    param(
        [Parameter(Mandatory)]$Manifest,
        [string]$RepoRoot
    )
    $all = @($Manifest.Files) + @($Manifest.Dirs)
    $ids = @($all | ForEach-Object { $_.Id })
    $dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes) { throw "manifest: duplicate artifact id(s): $($dupes -join ', ')" }

    foreach ($a in $all) {
        if (-not $a.Id -or -not $a.Repo -or -not $a.Destinations -or -not $a.Authority) {
            throw "manifest: artifact '$($a.Id)$($a.Repo)' is missing Id, Repo, Destinations or Authority"
        }
        if ($a.Authority -notin @('installed', 'repository')) {
            throw "manifest: artifact $($a.Id) has unknown authority '$($a.Authority)'"
        }
        if ($a.Authority -eq 'installed') {
            if (-not $a.CollectFrom) { throw "manifest: artifact $($a.Id) is installed-authoritative but has no CollectFrom" }
            if ($a.CollectFrom -notin @($a.Destinations)) { throw "manifest: artifact $($a.Id): CollectFrom is not one of its Destinations" }
        } elseif ($a.CollectFrom) {
            throw "manifest: artifact $($a.Id) is repository-authoritative and must not set CollectFrom"
        }
        foreach ($ex in @($a.ExcludeMembersOf | Where-Object { $_ })) {
            if ($ex -notin $ids) {
                throw "manifest: artifact $($a.Id): ExcludeMembersOf names unknown artifact '$ex'"
            }
        }
    }

    if ($RepoRoot) {
        $dirs = @($Manifest.Dirs)
        for ($i = 0; $i -lt $dirs.Count; $i++) {
            for ($j = $i + 1; $j -lt $dirs.Count; $j++) {
                $shared = @($dirs[$i].Destinations | Where-Object { $_ -in @($dirs[$j].Destinations) })
                if ($shared.Count -eq 0) { continue }
                $mi = @(Get-ArtifactMembers -RepoRoot $RepoRoot -Artifact $dirs[$i])
                $mj = @(Get-ArtifactMembers -RepoRoot $RepoRoot -Artifact $dirs[$j])
                $overlap = @($mi | Where-Object { $_ -in $mj })
                if ($overlap) {
                    throw "manifest: artifacts $($dirs[$i].Id) and $($dirs[$j].Id) share a destination and both own: $($overlap -join ', ')"
                }
            }
        }
    }
}

# Top-level entry names (skill directories, agent files) the repo side of a dir
# artifact currently owns. Membership is a REPO decision: which skills are shared is
# decided by where they sit in the repo tree, and this is the one place that reads it.
function Get-ArtifactMembers {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Artifact
    )
    $root = Join-Path $RepoRoot $Artifact.Repo
    if (-not (Test-Path $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root | ForEach-Object { $_.Name })
}

# The local files a dir artifact's collect should consider, after membership rules.
# $MemberIndex maps artifact Id -> its repo-side member names, computed ONCE before
# any collection mutates the repo tree, so every artifact filters against the same
# snapshot regardless of processing order.
function Select-ArtifactLocalFiles {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][hashtable]$MemberIndex
    )
    $files = @(Get-PlanFiles -Root $Artifact.CollectFrom -Filter $Artifact.Filter -Recurse $Artifact.Recurse)
    if ($Artifact.MembersFromRepo) {
        $members = @($MemberIndex[$Artifact.Id])
        $files = @($files | Where-Object { ($_.RelPath -split '[\\/]')[0] -in $members })
    }
    if ($Artifact.ExcludeMembersOf) {
        $excluded = @()
        foreach ($ex in @($Artifact.ExcludeMembersOf)) { $excluded += @($MemberIndex[$ex]) }
        $files = @($files | Where-Object { ($_.RelPath -split '[\\/]')[0] -notin $excluded })
    }
    if ($Artifact.ForeignMembers) {
        $files = @($files | Where-Object { -not (Test-ForeignMember -Artifact $Artifact -RelPath $_.RelPath) })
    }
    return @($files)
}

# Whether a path relative to a dir artifact's root lies in one of its ForeignMembers.
# Keyed on the first segment, like every other membership rule.
function Test-ForeignMember {
    param([Parameter(Mandatory)]$Artifact, [Parameter(Mandatory)][string]$RelPath)
    return (($RelPath -split '[\\/]')[0] -in @($Artifact.ForeignMembers))
}

# Whether an absolute local path lies in any dir artifact's foreign member. deploy asks
# this of every file its previous run wrote and this run did not, before pruning it.
function Test-ForeignDestination {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)
    foreach ($dir in @($Manifest.Dirs | Where-Object { $_.ForeignMembers })) {
        foreach ($root in @($dir.Destinations)) {
            $prefix = $root.TrimEnd('\', '/') + '\'
            if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-ForeignMember -Artifact $dir -RelPath $Path.Substring($prefix.Length))) {
                return $true
            }
        }
    }
    return $false
}

# Which installed-authoritative artifacts a set of repo-side changes could collide
# with. Pure: takes the changed paths (forward-slash repo-relative, as git prints
# them) and returns (Id, RepoPath, LocalPath) triples for collect to content-compare.
# The comparison itself stays in collect.ps1 -- this function decides candidacy, so
# candidacy is unit-testable without a git repo or a filesystem.
function Get-DivergenceCandidates {
    param(
        [string[]]$ChangedRepoPaths,
        [Parameter(Mandatory)]$Manifest
    )
    $candidates = @()
    foreach ($a in @($Manifest.Files)) {
        if ($a.Authority -ne 'installed') { continue }
        $prefix = $a.Repo.Replace('\', '/')
        foreach ($p in @($ChangedRepoPaths)) {
            if ($p -eq $prefix) {
                $candidates += [pscustomobject]@{ Id = $a.Id; RepoPath = $p; LocalPath = $a.CollectFrom }
            }
        }
    }
    foreach ($a in @($Manifest.Dirs)) {
        if ($a.Authority -ne 'installed') { continue }
        $prefix = $a.Repo.Replace('\', '/')
        foreach ($p in @($ChangedRepoPaths)) {
            if ($p -like "$prefix/*") {
                $rel = $p.Substring($prefix.Length + 1)
                # Collect never reads a foreign member, so a repo-side change to one
                # (its removal, above all) cannot collide with anything collect writes.
                if (Test-ForeignMember -Artifact $a -RelPath $rel) { continue }
                # String concat, not Join-Path: PowerShell 5.1's Join-Path validates
                # that the DRIVE exists, which makes this pure function untestable
                # with synthetic paths and couples candidacy to the filesystem.
                $candidates += [pscustomobject]@{
                    Id        = $a.Id
                    RepoPath  = $p
                    LocalPath = ($a.CollectFrom.TrimEnd('\') + '\' + $rel.Replace('/', '\'))
                }
            }
        }
    }
    return @($candidates)
}

# --- Derived instruction files (Codex AGENTS.md) ------------------------------
# ~/.codex/AGENTS.md and <Desktop>\AGENTS.md are built, not authored: the matching
# CLAUDE.md minus its <!-- claude-only --> ... <!-- /claude-only --> blocks, plus the
# repo's AGENTS.extra.md fragment. One source of shared facts; editing the generated
# file is always wrong, which is why it is repository-authoritative and carries a
# header saying so.
#
# Unbalanced or nested markers THROW rather than best-effort: a missing close marker
# would otherwise strip (or leak) half the file silently, and a generated
# instructions file that is silently wrong is worse than a failed build.
function Build-DerivedInstructions {
    param(
        [Parameter(Mandatory)][string]$SourceText,
        [string]$ExtraText,
        [Parameter(Mandatory)][string]$SourceLabel,
        [string]$ExtraLabel
    )
    $open  = [regex]::Matches($SourceText, '<!--\s*claude-only\s*-->').Count
    $close = [regex]::Matches($SourceText, '<!--\s*/claude-only\s*-->').Count
    if ($open -ne $close) {
        throw "$SourceLabel has $open opening claude-only marker(s) but $close closing marker(s); fix the markers before deriving"
    }
    $body = [regex]::Replace($SourceText, '(?s)<!--\s*claude-only\s*-->.*?<!--\s*/claude-only\s*-->[ \t]*\r?\n?', '')
    # Leftover check matches MARKER SYNTAX, not the bare phrase: prose legitimately
    # says "claude-only" when documenting the markers themselves.
    if ($body -match '<!--\s*/?claude-only\s*-->') {
        throw "$SourceLabel still contains a claude-only marker after stripping; markers are nested or malformed"
    }
    # LF throughout: .gitattributes checks every text file out with LF on every
    # machine, and a CRLF-built output would compare "stale" against its own LF
    # checkout on the next machine forever.
    $body = [regex]::Replace($body, '(\r?\n){3,}', "`n`n")

    $note = "<!-- GENERATED from $SourceLabel"
    if ($ExtraLabel) { $note += " + $ExtraLabel" }
    $note += " -- do not edit this file; edit the sources, then run collect.ps1 -->"

    $out = $note + "`n" + $body.TrimEnd() + "`n"
    if ($ExtraText -and $ExtraText.Trim()) {
        $out += "`n" + $ExtraText.Trim() + "`n"
    }
    return $out.Replace("`r`n", "`n")
}

# --- Derived agent definition (the directed subagent) -------------------------
# directed-agent\directed.md is "System Prompt.txt" wearing the frontmatter from
# directed-agent\directed.head.md: the head first (Claude Code reads the agent's name,
# description and model from it), any prose the head carries after its frontmatter, then
# the prompt verbatim. A subagent's file body REPLACES the built-in general-purpose
# prompt outright, so this is how a delegated worker runs under the same rules as the
# session that spawned it, with nothing else in between.
#
# The GENERATED marker goes inside the frontmatter as a YAML comment, not at the top of
# the body: the body is the subagent's system prompt, and a marker there would be read by
# the model on every spawn.
function Build-AgentDefinition {
    param(
        [Parameter(Mandatory)][string]$SourceText,
        [Parameter(Mandatory)][string]$HeadText,
        [Parameter(Mandatory)][string]$SourceLabel,
        [Parameter(Mandatory)][string]$HeadLabel
    )
    $head = $HeadText.Replace("`r`n", "`n")
    if ($head -notmatch '(?s)^---\n.*?\n---\n') {
        throw "$HeadLabel must open with a YAML frontmatter block (--- ... ---); Claude Code does not load an agent without one"
    }
    if ($head -notmatch '(?m)^name:\s*\S')        { throw "$HeadLabel frontmatter declares no name" }
    if ($head -notmatch '(?m)^description:\s*\S') { throw "$HeadLabel frontmatter declares no description" }

    $note = "# GENERATED from $SourceLabel + $HeadLabel -- do not edit this file; edit the sources, then run collect.ps1"
    $head = "---`n" + $note + "`n" + $head.Substring(4)
    $body = $SourceText.Replace("`r`n", "`n").Trim()
    return $head.TrimEnd() + "`n`n" + $body + "`n"
}

# The content one generated artifact should have right now, built from its sources in
# the repo. Shared by Update-GeneratedArtifacts (writes the repo copy) and the
# SessionStart hook global\refresh-directed-agent.ps1 (writes the deployed copy), so the
# two can never disagree about what "current" means.
function Get-GeneratedArtifactContent {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Artifact
    )
    $srcPath = Join-Path $RepoRoot $Artifact.GeneratedFrom
    if (-not (Test-Path $srcPath)) {
        throw "generated artifact $($Artifact.Id): source $($Artifact.GeneratedFrom) is missing from the repo"
    }
    $source = Get-Content $srcPath -Raw -Encoding UTF8
    $extraText = ''
    $extraLabel = $null
    if ($Artifact.GeneratedExtra) {
        $extraPath = Join-Path $RepoRoot $Artifact.GeneratedExtra
        if (Test-Path $extraPath) {
            $extraText  = Get-Content $extraPath -Raw -Encoding UTF8
            $extraLabel = $Artifact.GeneratedExtra
        }
    }
    switch ($Artifact.Builder) {
        'agent' {
            # The head is the frontmatter; without it there is no agent, so a missing
            # fragment is a refusal here rather than an optional extra as it is below.
            if (-not $extraLabel) {
                throw "generated artifact $($Artifact.Id): head fragment $($Artifact.GeneratedExtra) is missing from the repo"
            }
            return Build-AgentDefinition -SourceText $source -HeadText $extraText `
                                         -SourceLabel $Artifact.GeneratedFrom -HeadLabel $extraLabel
        }
        default {
            return Build-DerivedInstructions -SourceText $source -ExtraText $extraText `
                                             -SourceLabel $Artifact.GeneratedFrom -ExtraLabel $extraLabel
        }
    }
}

# Rebuild every generated artifact in the repo (or, with -Check, report which are
# stale without writing). collect.ps1 rebuilds after collection so the outputs track
# freshly collected sources; doctor.ps1 checks so a hand edit to a source that never
# went through collect -- or to a generated file directly -- is named, not silent.
function Update-GeneratedArtifacts {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Manifest,
        [switch]$Check
    )
    $results = @()
    foreach ($a in @($Manifest.Files | Where-Object { $_.GeneratedFrom })) {
        $built = Get-GeneratedArtifactContent -RepoRoot $RepoRoot -Artifact $a
        $outPath = Join-Path $RepoRoot $a.Repo
        $current = $null
        # Line-ending-insensitive comparison, same reason publish.ps1 normalizes:
        # autocrlf history means an older checkout can hold CRLF while the build is LF,
        # and that difference is git's business, not staleness.
        if (Test-Path $outPath) { $current = (Get-Content $outPath -Raw -Encoding UTF8).Replace("`r`n", "`n") }

        if ($current -eq $built) {
            $results += [pscustomobject]@{ Label = $a.Repo; State = 'current' }
        } elseif ($Check) {
            $results += [pscustomobject]@{ Label = $a.Repo; State = 'stale' }
        } else {
            Write-TextFile -Path $outPath -Content $built
            $results += [pscustomobject]@{ Label = $a.Repo; State = 'rebuilt' }
        }
    }
    return @($results)
}

# Enumerate one Dirs entry, in either direction, returning each file's path together
# with its path RELATIVE to the set root.
#
# The relative path is the whole point. collect, deploy and doctor used to build their
# own file lists with $_.Name, which is only correct while every synced directory is
# flat -- skills are not, and 'SKILL.md' as an identity would have collapsed all seven
# of them onto each other. Routing all three through here means the question "what is
# in this set?" has one answer.
function Get-PlanFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Filter = '*',
        [bool]$Recurse = $false
    )
    if (-not (Test-Path $Root)) { return @() }
    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $rootFull -Filter $Filter -File -Recurse:$Recurse |
        ForEach-Object {
            [pscustomobject]@{
                FullName = $_.FullName
                RelPath  = $_.FullName.Substring($rootFull.Length + 1)
            }
        })
}

# --- The machine-specific values the repo refuses to hardcode -----------------
#   {{USERNAME}}     the Windows account name
#   {{DESKTOP}}      the real Desktop, forward-slashed (OneDrive-aware)
#   {{CONFIG_ROOT}}  the absolute path of this repo, forward-slashed
#
# CONFIG_ROOT and DESKTOP exist because prose is executed too. A skill telling Claude to
# run a script under '$HOME/Desktop/claude-config' is simply wrong on a machine with
# OneDrive Known Folder Move -- the same literal-Desktop assumption Get-DesktopPath
# prevents in code -- and no amount of correctness in the .ps1 files repairs it, because
# the .md is what Claude reads and acts on.
#
# They are tokens rather than a convention because a convention has nothing enforcing it:
# the username sweep in collect.ps1 cannot see a hardcoded Desktop path, since most ways
# of spelling one ('$HOME/...', '$env:USERPROFILE\...', a bare relative 'Desktop\...')
# contain no username at all. doctor.ps1 fails on any that survive.
#
# Forward slashes because a skill's instructions get executed through whichever shell
# Claude reaches for: PowerShell accepts 'C:/Users/...' everywhere, and Git Bash reads
# backslashes as escapes. global\settings.json already spelled its path this way.
#
# String.Replace, not -replace: the tokens' casing is fixed, and a regex replacement
# would give special meaning to '$' in a username or a path.
function Expand-Tokens {
    param([string]$Text, [string]$UserName, [string]$ConfigRoot, [string]$Desktop)
    return $Text.Replace('{{CONFIG_ROOT}}', $ConfigRoot).
                 Replace('{{DESKTOP}}',     $Desktop).
                 Replace('{{USERNAME}}',    $UserName)
}

# The reverse direction: machine paths -> tokens, used by collect.ps1. Lives here
# beside Expand-Tokens so the two directions are testable as a round trip -- the pair
# disagreeing by a single slash makes every collected file look changed.
#
# Both slash spellings are collapsed because a deployed file may legitimately hold
# either: deploy writes the forward-slashed form, but a human editing a deployed file
# by hand types whatever their shell showed them. Tokenizing only one would leave the
# other as a hardcoded local path -- the exact failure these tokens exist to prevent.
# CONFIG_ROOT before DESKTOP, because the Desktop is a PREFIX of the config root;
# the callers pass values in that order.
function ConvertTo-RepoTokens {
    param(
        [string]$Text,
        [Parameter(Mandatory)][string]$ConfigRoot,
        [Parameter(Mandatory)][string]$Desktop
    )
    $replacements = @(
        @{ Token = '{{CONFIG_ROOT}}'; Value = $ConfigRoot }
        @{ Token = '{{DESKTOP}}';     Value = $Desktop }
    )
    foreach ($r in $replacements) {
        $Text = $Text -replace [regex]::Escape($r.Value), $r.Token
        $Text = $Text -replace [regex]::Escape($r.Value.Replace('/', '\')), $r.Token
    }
    return $Text
}

# What {{CONFIG_ROOT}} and {{DESKTOP}} expand to. One function each, because collect.ps1
# REVERSES these substitutions while deploy.ps1 and doctor.ps1 apply them; the two
# directions disagreeing by a single slash would make every round trip look like a change.
#
# Reversing is the direction with an ordering constraint, and collect.ps1 honours it:
# the config root is a PREFIX of nothing but is PREFIXED BY the Desktop, so tokenizing
# the Desktop first would turn '<Desktop>/claude-config' into '{{DESKTOP}}/claude-config'
# and the longer, more specific token would never match again.
function Get-ConfigRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return $RepoRoot.Replace('\', '/').TrimEnd('/')
}

function Get-DesktopToken {
    return (Get-DesktopPath).Replace('\', '/').TrimEnd('/')
}

# --- secrets.json, read the same way by deploy.ps1 and doctor.ps1 ------------
# Returns the registry entries, or $null when the file is absent. Invalid JSON
# THROWS rather than returning empty: silently checking zero secrets is how a
# store that nothing can read still reports as fine.
function Get-SecretsRegistry {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path $RepoRoot 'secrets.json'
    if (-not (Test-Path $path)) { return $null }
    return @((Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json).secrets)
}

# --- .backups\ --------------------------------------------------------------
# deploy.ps1 names its backup directories with a sortable timestamp. Anything
# else under .backups\ belongs to something else -- apply-terminal-keybinding.ps1
# keeps its own snapshots in .backups\terminal\ -- and must not be mistaken for a
# deploy backup. Name-sorting alone does not separate them: 'terminal' sorts
# ABOVE every digit, so restore.ps1 -Latest used to announce it as a newer backup
# it was skipping, on every single run.
# Newest first; the stamp format sorts chronologically as text.
function Get-BackupDirs {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root = Join-Path $RepoRoot '.backups'
    if (-not (Test-Path $root)) { return @() }
    return @(Get-ChildItem $root -Directory |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}$' } |
        Sort-Object Name -Descending)
}

# --- PowerShell profile discovery -------------------------------------------
# Windows PowerShell 5.1 reads Documents\WindowsPowerShell\, PowerShell 7+ reads
# Documents\PowerShell\. Both must be wired up or the claude-* functions exist in
# only one of the user's shells (this was a real, months-long silent failure).
#
# Documents is resolved via GetFolderPath('MyDocuments'), NOT "$env:USERPROFILE\Documents":
# OneDrive Known Folder Move redirects Documents, and hardcoding the literal path
# installs into a directory the user's shells never read.
function Get-ProfilePaths {
    $paths = @()

    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ($docs) {
        $paths += Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'  # 5.1
        $paths += Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'         # 7+
    }

    # Ask pwsh itself, in case it reports somewhere the two paths above miss.
    #
    # The '2>$null' is why the preference is relaxed here. Redirecting a native command's
    # stderr makes each line a PowerShell error record, and this file is dot-sourced into
    # deploy/collect/restore/publish/sync-config, all of which set
    # $ErrorActionPreference = 'Stop' -- which makes that record terminating. The catch
    # below would then swallow it and quietly drop this path, so any startup message from
    # pwsh (a profile warning, a preview-version notice) would cost us the very path this
    # block exists to find, with nothing reported. Same shape as the Test-JsonValid bug:
    # a catch hiding a failure rather than handling one.
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $p = & $pwsh.Source -NoProfile -NonInteractive -Command '$PROFILE.CurrentUserCurrentHost' 2>$null
            if ($p) { $paths += ([string]$p).Trim() }
        } catch {
            # pwsh present but unusable -- the two literal paths above still stand.
        } finally {
            $ErrorActionPreference = $previousEap
        }
    }

    # And the shell running this script.
    if ($PROFILE) { $paths += [string]$PROFILE }

    $paths | Where-Object { $_ } | Select-Object -Unique
}

# --- Managed block injected into each profile -------------------------------
# The functions live in one synced file; each profile only gets a dot-source line.
# That keeps the install additive: a user's existing profile is never rewritten.
#
# Detection deliberately matches only the stable prefix, not the whole start line.
# The trailing text has already changed once (an em-dash became '--' when these scripts
# were made pure ASCII), and blocks written by the older version are still out there in
# real profiles. Matching the prefix means an existing block is recognised and REPLACED
# rather than missed and duplicated.
function Get-ClaudeBlockMarkers {
    @{
        Start         = '# --- Claude Code config (managed block) -- do not edit inside ---'
        End           = '# --- end Claude Code config ---'
        DetectPattern = [regex]::Escape('# --- Claude Code config (managed block)')
    }
}

function Get-ClaudeProfileBlock {
    $m = Get-ClaudeBlockMarkers
    @"
$($m.Start)
`$claudeFunctions = "`$env:USERPROFILE\.claude\claude-functions.ps1"
if (Test-Path `$claudeFunctions) { . `$claudeFunctions }
`$codexFunctions = "`$env:USERPROFILE\.codex\codex-functions.ps1"
if (Test-Path `$codexFunctions) { . `$codexFunctions }
$($m.End)
"@
}

function Test-ClaudeProfileBlock {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $m = Get-ClaudeBlockMarkers
    return (Get-Content $Path -Raw -Encoding UTF8) -match $m.DetectPattern
}

# Idempotent: appends the block if absent, replaces it in place if present but stale,
# leaves everything outside the markers untouched. Returns one of
# 'added' | 'updated' | 'unchanged' | 'would-add' | 'would-update'.
function Add-ClaudeProfileBlock {
    param(
        [string]$Path,
        [switch]$DryRun,
        [string]$BackupDir
    )

    $m     = Get-ClaudeBlockMarkers
    $block = Get-ClaudeProfileBlock
    $existing = if (Test-Path $Path) { Get-Content $Path -Raw -Encoding UTF8 } else { '' }

    $rx = [regex]("(?s)" + $m.DetectPattern + ".*?" + [regex]::Escape($m.End))
    $hasBlock = $rx.IsMatch($existing)

    if ($hasBlock) {
        $updated = $rx.Replace($existing, $block, 1)
        if ($updated -eq $existing) { return 'unchanged' }
        if ($DryRun) { return 'would-update' }
        $action = 'updated'
    } else {
        $sep = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }
        $updated = $existing.TrimEnd() + $sep + $block + "`r`n"
        if ($DryRun) { return 'would-add' }
        $action = 'added'
    }

    if ($BackupDir -and (Test-Path $Path)) {
        $leaf = Split-Path -Leaf (Split-Path -Parent $Path)   # WindowsPowerShell | PowerShell
        $dest = Join-Path $BackupDir "profile-$leaf.ps1"
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item $Path $dest -Force
    }

    Write-TextFile -Path $Path -Content $updated
    return $action
}

# --- Windows Terminal ------------------------------------------------------
# settings.json lives under a package path that differs across installs
# (stable / Preview / unpackaged), so probe all of them.
function Get-TerminalSettingsPaths {
    $paths = @()
    $pkgRoot = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path $pkgRoot) {
        Get-ChildItem $pkgRoot -Directory -Filter "Microsoft.WindowsTerminal*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $p = Join-Path $_.FullName "LocalState\settings.json"
                if (Test-Path $p) { $paths += $p }
            }
    }
    $unpackaged = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json"
    if (Test-Path $unpackaged) { $paths += $unpackaged }
    $paths | Select-Object -Unique
}

# Validate JSON, tolerating comments and trailing commas the way Windows Terminal does.
#
# System.Text.Json is the clean way to do this, but it does NOT exist on Windows
# PowerShell 5.1 (.NET Framework 4.x ships it only as an optional NuGet package).
# Without the type check below, the type lookup threw, the catch swallowed it, and this
# returned $false for EVERY input under 5.1 -- which made doctor.ps1 report perfectly
# good settings files as corrupt, and made apply-terminal-keybinding.ps1 refuse to add
# the Shift+Enter binding while blaming "unexpected structure".
function Test-JsonValid {
    param([string]$Json)

    if ('System.Text.Json.JsonDocument' -as [type]) {
        try {
            $opts = [System.Text.Json.JsonDocumentOptions]::new()
            $opts.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
            $opts.AllowTrailingCommas = $true
            [void][System.Text.Json.JsonDocument]::Parse($Json, $opts)
            return $true
        } catch {
            return $false
        }
    }

    # 5.1 fallback: ConvertFrom-Json rejects comments and trailing commas, so strip both
    # first. The comment pattern is anchored to the start of a line, so a "//" inside a
    # string (a URL, say) is left alone.
    try {
        $stripped = [regex]::Replace($Json,     '(?m)^\s*//.*$', '')
        $stripped = [regex]::Replace($stripped, ',(\s*[}\]])',   '$1')
        [void]($stripped | ConvertFrom-Json)
        return $true
    } catch {
        return $false
    }
}

# Returns @{ Path; DefaultProfileName; DefaultProfileGuid } for the first readable
# Terminal settings.json, or $null. Used by doctor.ps1 to answer the question that
# actually matters: does the shell the user's Terminal opens by default get the
# claude-* functions?
function Get-TerminalDefaultProfile {
    foreach ($path in @(Get-TerminalSettingsPaths)) {
        try {
            $raw = (Get-Content $path -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
            $j = $raw | ConvertFrom-Json
            $guid = $j.defaultProfile
            $name = ($j.profiles.list | Where-Object { $_.guid -eq $guid } | Select-Object -First 1).name
            return @{ Path = $path; DefaultProfileName = $name; DefaultProfileGuid = $guid }
        } catch { continue }
    }
    return $null
}
