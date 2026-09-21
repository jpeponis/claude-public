# deploy.ps1 -- Deploy repo agent config (Claude + Codex) to the local machine with
# the username resolved.
# Usage:
#   powershell -ExecutionPolicy Bypass -File deploy.ps1
#   powershell -ExecutionPolicy Bypass -File deploy.ps1 -DryRun          # preview, write nothing
#   powershell -ExecutionPolicy Bypass -File deploy.ps1 -KeepBackups 40  # keep more history
#
# What gets deployed, and what is deliberately left out, is described once in
# Get-ArtifactManifest (lib\Common.ps1) and shared with collect.ps1 and doctor.ps1.
# A multi-destination artifact deploys to every destination; if any write fails, the
# whole run rolls back from this run's backups rather than leaving a half-updated
# machine.

[CmdletBinding()]
param(
    [switch]$DryRun,
    # How many timestamped backup directories to keep. Each deploy that changes
    # anything adds one; without a cap they accumulate for the life of the repo.
    [ValidateRange(1, 1000)][int]$KeepBackups = 20
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$username   = $env:USERNAME
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$codexHome  = Join-Path $env:USERPROFILE ".codex"
$agentsHome = Join-Path $env:USERPROFILE ".agents"
$desktopDir = Get-DesktopPath
$configRoot = Get-ConfigRoot -RepoRoot $repoRoot
$desktopTok = Get-DesktopToken
$plan       = Get-ArtifactManifest -ClaudeHome $claudeHome -CodexHome $codexHome -AgentsHome $agentsHome -DesktopDir $desktopDir
Test-ArtifactManifest -Manifest $plan -RepoRoot $repoRoot

# Files this script has deployed before. Pruning is limited to this list so a
# user's own skills/agents are never deleted just for being unknown to the repo.
# Read up front: it also tells the adoption notice below which existing files this
# script has never touched.
$deployedManifestPath = Join-Path $claudeHome ".deployed-manifest.json"
$previousDests = @()
if (Test-Path $deployedManifestPath) {
    try {
        $previousDests = @((Get-Content $deployedManifestPath -Raw | ConvertFrom-Json).deployed)
    } catch {
        Write-Host "[WARN] Could not read $deployedManifestPath; prune and adoption notices are off this run." -ForegroundColor Yellow
        $previousDests = @()
    }
}

function Say {
    param([string]$Text, [string]$Color = 'Gray', [switch]$Plan)
    $prefix = if ($DryRun -and $Plan) { "[DRY] " } else { "" }
    Write-Host "$prefix$Text" -ForegroundColor $Color
}

# Copy-Item does not create missing parent directories, and every backup path has one.
function Copy-ToBackup {
    param([string]$Path, [string]$Label)
    $dest = Join-Path $backupDir $Label
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -Path $Path -Destination $dest -Force
}

# --- Build flat list of all source->dest pairs for backup and deploy ---
# Label doubles as the path each file takes inside a backup directory, so it must be
# unique across the whole run. The repo-relative path covers the first destination;
# a multi-destination artifact's further projections get a 'proj<i>\' prefix, since
# the same repo file lands at two places and both may need backing up.
$allPairs = @()

foreach ($map in $plan.Files) {
    $dests = @($map.Destinations)
    for ($i = 0; $i -lt $dests.Count; $i++) {
        $label = if ($i -eq 0) { $map.Repo } else { Join-Path "proj$i" $map.Repo }
        $allPairs += @{ Source = (Join-Path $repoRoot $map.Repo); Dest = $dests[$i]; Label = $label }
    }
}
foreach ($dir in $plan.Dirs) {
    $repoFiles = @(Get-PlanFiles -Root (Join-Path $repoRoot $dir.Repo) -Filter $dir.Filter -Recurse $dir.Recurse)
    $dests = @($dir.Destinations)
    for ($i = 0; $i -lt $dests.Count; $i++) {
        foreach ($file in $repoFiles) {
            $rel = Join-Path $dir.Repo $file.RelPath
            $label = if ($i -eq 0) { $rel } else { Join-Path "proj$i" $rel }
            $allPairs += @{
                Source = $file.FullName
                Dest   = (Join-Path $dests[$i] $file.RelPath)
                Label  = $label
            }
        }
    }
}

# --- Resolve what each pair would write, and whether that is a change ---------
# Done before anything is backed up, because "would this change?" is what the backup
# step needs to know. Backing up every destination that merely EXISTS means a deploy
# that changes nothing still writes a full snapshot, and since retention keeps only the
# newest N directories, N no-op deploys are enough to evict every snapshot taken before
# a real edit -- a window that reports N generations of depth while holding one. The
# window has to count changes, not runs.
foreach ($pair in $allPairs) {
    $pair.Missing = -not (Test-Path $pair.Source)
    if ($pair.Missing) { continue }
    $pair.Content = Expand-Tokens -Text (Read-TextFile $pair.Source) `
                                  -UserName $username -ConfigRoot $configRoot -Desktop $desktopTok
    $pair.Existed = Test-Path $pair.Dest
    $pair.Changed = -not ($pair.Existed -and ((Read-TextFile $pair.Dest) -eq $pair.Content))
}

# --- Backup the files this run is actually going to overwrite ----------------
# Each backup directory gets a manifest.json recording Label -> Dest so restore.ps1
# can put files back exactly where they came from instead of inferring it. A file that
# does not exist yet is skipped: there is nothing of yours to preserve.
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backupDir = Join-Path $repoRoot ".backups\$timestamp"
$backupEntries = @()

foreach ($pair in $allPairs) {
    if ($pair.Missing -or -not $pair.Changed -or -not $pair.Existed) { continue }
    $backupEntries += [ordered]@{ Label = $pair.Label; Dest = $pair.Dest }
    if (-not $DryRun) { Copy-ToBackup -Path $pair.Dest -Label $pair.Label }
}

if ($backupEntries.Count -gt 0) {
    Say "Backing up $($backupEntries.Count) file(s) about to be overwritten, to .backups\$timestamp\" 'Cyan' -Plan
}

# --- Deploy files ---
# The whole write phase is transactional against this run's backups: if any write
# throws, every file already written is put back (from backup) or removed (if it did
# not exist before), and the failure is rethrown. A half-updated machine that doctor
# can detect but nothing can undo is exactly what the backup directory exists to
# prevent -- so use it at the moment it matters, not only on request.
$written   = 0
$unchanged = 0
$skipped   = 0
$deleted   = 0
$adopted   = 0
$deployedDests = @()
$writtenPairs  = @()

try {
    foreach ($pair in $allPairs) {
        if ($pair.Missing) {
            Say "[SKIP] $($pair.Label) (not in repo)" 'Yellow'
            $skipped++
            continue
        }

        $deployedDests += $pair.Dest

        if (-not $pair.Changed) {
            Say "[SAME] $($pair.Label)" 'DarkGray'
            $unchanged++
            continue
        }

        # Adoption notice: this destination exists, differs, and no previous deploy of
        # ours ever wrote it -- we are about to take over a file something else put
        # there (a pre-existing AGENTS.md, a hand-made agent). The backup taken above
        # preserves it; the notice is so the takeover is a decision someone saw.
        if ($pair.Existed -and $previousDests.Count -gt 0 -and ($pair.Dest -notin $previousDests)) {
            Say "[ADPT] $($pair.Label) -- existing file not previously managed; original kept in .backups\$timestamp\" 'Yellow' -Plan
            $adopted++
        }

        if ($DryRun) {
            Say "[OK]   $($pair.Label) -> $($pair.Dest)" 'Green' -Plan
        } else {
            Write-TextFile -Path $pair.Dest -Content $pair.Content
            $writtenPairs += $pair
            Say "[OK]   $($pair.Label) -> $($pair.Dest)" 'Green'
        }
        $written++
    }
} catch {
    Say "" 'Red'
    Say "DEPLOY FAILED: $($_.Exception.Message)" 'Red'
    Say "Rolling back the $($writtenPairs.Count) file(s) this run already wrote..." 'Yellow'
    foreach ($p in $writtenPairs) {
        $bak = Join-Path $backupDir $p.Label
        if (Test-Path $bak) {
            Copy-Item $bak $p.Dest -Force
            Say "  restored $($p.Label)" 'Yellow'
        } elseif (-not $p.Existed) {
            Remove-Item $p.Dest -Force -ErrorAction SilentlyContinue
            Say "  removed  $($p.Label) (did not exist before this run)" 'Yellow'
        }
    }
    throw
}

# --- Prune files this repo previously deployed and no longer ships -----------
# Bounded by the previous run's manifest (read above). A file we never deployed is
# never deleted, so a user's own commands/my-thing.md survives; a skill removed from
# the repo does not.
#
# Nor is anything inside a foreign member (manifest ForeignMembers): it belongs to
# another program even if an earlier deploy wrote it, so it is released -- dropped
# from the deployed manifest below -- and left where it is.

$released = 0
foreach ($stale in ($previousDests | Where-Object { $_ -and ($_ -notin $deployedDests) })) {
    if (-not (Test-Path $stale)) { continue }
    if (Test-ForeignDestination -Manifest $plan -Path $stale) { $released++; continue }
    if ($DryRun) {
        Say "[DEL]  $stale (removed from repo)" 'Red' -Plan
    } else {
        # Keep enough of the path in the label to stay unique. 'pruned\<leaf>' alone
        # collides whenever two synced directories hold the same filename -- agents\notes.md
        # and workflows\notes.md would overwrite each other in the backup AND produce two
        # manifest entries with the same Label pointing at different destinations, so a
        # restore would put one file's content back at the other file's path. Two
        # segments were enough while every synced directory was flat; skills are nested,
        # and every one of them ends in 'SKILL.md', so take three.
        $segments = @($stale -split '[\\/]' | Where-Object { $_ }) | Select-Object -Last 3
        $label = Join-Path "pruned" ($segments -join '\')
        Copy-ToBackup -Path $stale -Label $label
        $backupEntries += [ordered]@{ Label = $label; Dest = $stale }
        Remove-Item $stale -Force
        Say "[DEL]  $stale (removed from repo)" 'Red'
    }
    $deleted++
}

# --- Write the manifests ----------------------------------------------------
if (-not $DryRun) {
    if ($backupEntries.Count -gt 0) {
        Write-TextFile -Path (Join-Path $backupDir "manifest.json") -Content (
            [ordered]@{ timestamp = $timestamp; files = $backupEntries } | ConvertTo-Json -Depth 5
        )
    }
    Write-TextFile -Path $deployedManifestPath -Content (
        [ordered]@{ updated = (Get-Date -Format 'o'); deployed = $deployedDests } | ConvertTo-Json -Depth 5
    )

    # Machine-local repo pointers: the function files resolve the repo through the
    # '.config-root' beside them instead of assuming <Desktop>\claude-config, so an
    # install anywhere still finds "System Prompt.txt" and Get-Secret.ps1. Written
    # every deploy; never synced, never pruned (not in the artifact manifest).
    foreach ($targetHome in @($claudeHome, $codexHome)) {
        Write-TextFile -Path (Join-Path $targetHome '.config-root') -Content $repoRoot
    }

    # The divergence-guard base: which commit this machine's installed tree now
    # reflects. collect.ps1 refuses to overwrite repo changes that landed after this
    # commit while the installed copy disagrees. Untracked; meaningful only here.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Index, not '| Select-Object -First 1': that stops the pipeline early, which in
        # 5.1 kills git and leaves $LASTEXITCODE at -1, so the file was written only
        # when git happened to exit first.
        $head = @(& git -C $repoRoot rev-parse HEAD 2>$null)[0]
        if ($LASTEXITCODE -eq 0 -and $head) {
            Write-TextFile -Path (Join-Path $repoRoot '.last-deployed') -Content ([string]$head).Trim()
        }
    } catch { }
    finally { $ErrorActionPreference = $previousEap }
}

# --- Retention: keep the newest $KeepBackups timestamped backups -------------
# Only timestamped directories are considered; .backups\terminal\ belongs to
# apply-terminal-keybinding.ps1 and is left alone.
$oldBackups = @(Get-BackupDirs -RepoRoot $repoRoot | Select-Object -Skip $KeepBackups)
foreach ($old in $oldBackups) {
    if ($DryRun) {
        Say "[DEL]  .backups\$($old.Name) (beyond the newest $KeepBackups)" 'DarkGray' -Plan
    } else {
        Remove-Item $old.FullName -Recurse -Force
    }
}
if ($oldBackups.Count -gt 0 -and -not $DryRun) {
    Say "Pruned $($oldBackups.Count) backup director(ies) beyond the newest $KeepBackups." 'DarkGray'
}

Write-Host ""
$notes = ""
if ($adopted -gt 0)  { $notes += ", adopted $adopted" }
if ($released -gt 0) { $notes += ", released $released (another program's; left in place)" }
Say "Wrote $written files, unchanged $unchanged, skipped $skipped, pruned $deleted$notes." 'Cyan' -Plan

# --- PowerShell profiles: additive, and BOTH editions ------------------------
# Windows PowerShell 5.1 and PowerShell 7+ read different profile paths. Wiring only
# one leaves the claude-*/codex-* functions undefined in the other, which is silent:
# deploy reports success and the functions simply do not exist. So inject into every
# profile path we can find, and never rewrite anything outside our markers.
Write-Host ""
Say "PowerShell profiles (dot-source the claude/codex function files):" 'Cyan'
foreach ($profilePath in @(Get-ProfilePaths)) {
    $result = Add-ClaudeProfileBlock -Path $profilePath -DryRun:$DryRun -BackupDir $backupDir
    $color = if ($result -eq 'unchanged') { 'DarkGray' } else { 'Green' }
    Say ("  [{0,-12}] {1}" -f $result, $profilePath) $color
}

# --- Reminders: encrypted secret store (DPAPI, per-user/per-machine) --------
# These .enc files cannot be carried between machines; each machine re-encrypts its
# own secrets locally with Set-Secret.ps1. Registry lives in secrets.json so the
# scripts stay identical across the private and public repos.
$secretChecks = @()
try {
    $secretChecks = @(Get-SecretsRegistry -RepoRoot $repoRoot)
} catch {
    Say "[WARN] Could not parse secrets.json; skipping secret checks." 'Yellow'
}
foreach ($s in $secretChecks) {
    $encPath = Join-Path $claudeHome ".$($s.name).enc"
    if (-not (Test-Path $encPath)) {
        Write-Host ""
        Write-Host "NOTE: encrypted secret '$($s.name)' not found at $encPath" -ForegroundColor Yellow
        Write-Host "  Needed for: $($s.purpose)" -ForegroundColor Yellow
        Write-Host "  Create it on this machine (DPAPI, current user only):" -ForegroundColor Yellow
        Write-Host "    & `"$repoRoot\Set-Secret.ps1`" -Name $($s.name)" -ForegroundColor White
    }
}

# --- User-level env var required for always-on MCP Tool Search --------------
if (-not ([Environment]::GetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'User'))) {
    Write-Host ""
    if ($DryRun) {
        Say "Would set User env var ENABLE_TOOL_SEARCH=true (always-on MCP Tool Search)." 'Yellow' -Plan
    } else {
        [Environment]::SetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'true', 'User')
        Write-Host "Set User env var ENABLE_TOOL_SEARCH=true (always-on MCP Tool Search)." -ForegroundColor Green
    }
}

# --- Windows Terminal: ensure Shift+Enter sends a newline -------------------
$wtScript = Join-Path $repoRoot "apply-terminal-keybinding.ps1"
if (Test-Path $wtScript) {
    Write-Host ""
    try {
        & $wtScript -DryRun:$DryRun
    } catch {
        Write-Host "[WARN] apply-terminal-keybinding.ps1 failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete -- nothing was written. Re-run without -DryRun to apply." -ForegroundColor Yellow
} else {
    Write-Host "Restart Claude Code, and open a NEW terminal tab, for changes to take effect." -ForegroundColor Cyan
    Write-Host "Verify with: powershell -ExecutionPolicy Bypass -File `"$repoRoot\doctor.ps1`"" -ForegroundColor Cyan
}
