# deploy.ps1 -- Deploy repo Claude Code config to local machine with username resolved
# Usage:
#   powershell -ExecutionPolicy Bypass -File deploy.ps1
#   powershell -ExecutionPolicy Bypass -File deploy.ps1 -DryRun          # preview, write nothing
#   powershell -ExecutionPolicy Bypass -File deploy.ps1 -KeepBackups 40  # keep more history
#
# What gets deployed, and what is deliberately left out, is described once in
# Get-SyncPlan (lib\Common.ps1) and shared with collect.ps1 and doctor.ps1.

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
$desktopDir = Get-DesktopPath
$configRoot = Get-ConfigRoot -RepoRoot $repoRoot
$desktopTok = Get-DesktopToken
$plan       = Get-SyncPlan -ClaudeHome $claudeHome -DesktopDir $desktopDir

# Files this script has deployed before. Pruning is limited to this list so a
# user's own skills/agents are never deleted just for being unknown to the repo.
$deployedManifestPath = Join-Path $claudeHome ".deployed-manifest.json"

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
# unique across the whole run; the repo-relative path already is.
$allPairs = @()

foreach ($map in $plan.Files) {
    $allPairs += @{ Source = (Join-Path $repoRoot $map.Repo); Dest = $map.Local; Label = $map.Repo }
}
foreach ($dir in $plan.Dirs) {
    foreach ($file in (Get-PlanFiles -Root (Join-Path $repoRoot $dir.Repo) -Filter $dir.Filter -Recurse $dir.Recurse)) {
        $allPairs += @{
            Source = $file.FullName
            Dest   = (Join-Path $dir.Local $file.RelPath)
            Label  = (Join-Path $dir.Repo $file.RelPath)
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
    $pair.Content = Expand-Tokens -Text (Get-Content -Path $pair.Source -Raw -Encoding UTF8) `
                                  -UserName $username -ConfigRoot $configRoot -Desktop $desktopTok
    $pair.Existed = Test-Path $pair.Dest
    $pair.Changed = -not ($pair.Existed -and
                          ((Get-Content -Path $pair.Dest -Raw -Encoding UTF8) -eq $pair.Content))
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
$written   = 0
$unchanged = 0
$skipped   = 0
$deleted   = 0
$deployedDests = @()

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

    if ($DryRun) {
        Say "[OK]   $($pair.Label) -> $($pair.Dest)" 'Green' -Plan
    } else {
        Write-TextFile -Path $pair.Dest -Content $pair.Content
        Say "[OK]   $($pair.Label) -> $($pair.Dest)" 'Green'
    }
    $written++
}

# --- Prune files this repo previously deployed and no longer ships -----------
# Bounded by the previous run's manifest. A file we never deployed is never deleted,
# so a user's own commands/my-thing.md survives; a skill removed from the repo does not.
$previousDests = @()
if (Test-Path $deployedManifestPath) {
    try {
        $previousDests = @((Get-Content $deployedManifestPath -Raw | ConvertFrom-Json).deployed)
    } catch {
        Say "[WARN] Could not read $deployedManifestPath; skipping prune this run." 'Yellow'
        $previousDests = @()
    }
}

foreach ($stale in ($previousDests | Where-Object { $_ -and ($_ -notin $deployedDests) })) {
    if (-not (Test-Path $stale)) { continue }
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
Say "Wrote $written files, unchanged $unchanged, skipped $skipped, pruned $deleted." 'Cyan' -Plan

# --- PowerShell profiles: additive, and BOTH editions ------------------------
# Windows PowerShell 5.1 and PowerShell 7+ read different profile paths. Wiring only
# one leaves the claude-* functions undefined in the other, which is silent: deploy
# reports success and the functions simply do not exist. So inject into every profile
# path we can find, and never rewrite anything outside our markers.
Write-Host ""
Say "PowerShell profiles (dot-source claude-functions.ps1):" 'Cyan'
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
