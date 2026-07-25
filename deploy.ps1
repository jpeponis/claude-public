# deploy.ps1 — Deploy repo Claude Code config to local machine with username resolved
# Usage:
#   powershell -ExecutionPolicy Bypass -File deploy.ps1
#   powershell -ExecutionPolicy Bypass -File deploy.ps1 -DryRun    # preview, write nothing

[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$username   = $env:USERNAME
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Join-Path $env:USERPROFILE "Desktop"

# Files this script has deployed before. Pruning is limited to this list so a
# user's own skills/agents are never deleted just for being unknown to the repo.
$deployedManifestPath = Join-Path $claudeHome ".deployed-manifest.json"

function Say {
    param([string]$Text, [string]$Color = 'Gray', [switch]$Plan)
    $prefix = if ($DryRun -and $Plan) { "[DRY] " } else { "" }
    Write-Host "$prefix$Text" -ForegroundColor $Color
}

# --- Individual file mappings ---
# NOTE: Repo-native files ("System Prompt.txt", lib\, and the launcher / doctor / restore /
#       publish scripts) are run from the repo and deliberately not deployed.
# NOTE: ~/.claude/.*.enc secrets are NEVER deployed (DPAPI, per-user and per-machine).
#       Missing ones are reported at the end; see secrets.json for the registry.
# NOTE: The PowerShell profile is NOT in this list. Profiles are wired up additively
#       by Add-ClaudeProfileBlock below — see the profile section for why.
$fileMappings = @(
    @{ Source = "global\settings.json";                        Dest = "$claudeHome\settings.json" }
    @{ Source = "global\statusline-command.ps1";               Dest = "$claudeHome\statusline-command.ps1" }
    @{ Source = "powershell\claude-functions.ps1";             Dest = "$claudeHome\claude-functions.ps1" }
    @{ Source = "project-desktop\CLAUDE.md";                   Dest = "$desktopDir\CLAUDE.md" }
    @{ Source = "project-desktop\.claude\settings.local.json"; Dest = "$desktopDir\.claude\settings.local.json" }
)

# --- Directory mappings (each Filter synced as a unit) ---
$dirMappings = @(
    @{ SourceDir = "global\commands"; DestDir = "$claudeHome\commands"; Filter = "*.md" }
    @{ SourceDir = "global\agents";   DestDir = "$claudeHome\agents";  Filter = "*.md" }
    @{ SourceDir = "project-desktop\.claude\workflows"; DestDir = "$desktopDir\.claude\workflows"; Filter = "*.js" }
)

# --- Build flat list of all source->dest pairs for backup and deploy ---
$allPairs = @()

foreach ($map in $fileMappings) {
    $allPairs += @{ Source = (Join-Path $repoRoot $map.Source); Dest = $map.Dest; Label = $map.Source }
}
foreach ($dir in $dirMappings) {
    $srcDir = Join-Path $repoRoot $dir.SourceDir
    if (Test-Path $srcDir) {
        foreach ($file in (Get-ChildItem -Path $srcDir -Filter $dir.Filter -File)) {
            $relSource = Join-Path $dir.SourceDir $file.Name
            $allPairs += @{ Source = $file.FullName; Dest = (Join-Path $dir.DestDir $file.Name); Label = $relSource }
        }
    }
}

# --- Backup existing files ---
# Each backup directory gets a manifest.json recording Label -> Dest so restore.ps1
# can put files back exactly where they came from instead of inferring it.
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backupDir = Join-Path $repoRoot ".backups\$timestamp"
$backupEntries = @()

foreach ($pair in $allPairs) {
    if (Test-Path $pair.Dest) {
        $backupEntries += [ordered]@{ Label = $pair.Label; Dest = $pair.Dest }
        if (-not $DryRun) {
            $backupPath = Join-Path $backupDir $pair.Label
            $backupParent = Split-Path -Parent $backupPath
            if (-not (Test-Path $backupParent)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
            Copy-Item -Path $pair.Dest -Destination $backupPath -Force
        }
    }
}

if ($backupEntries.Count -gt 0) {
    Say "Backing up $($backupEntries.Count) existing files to .backups\$timestamp\" 'Cyan' -Plan
}

# --- Deploy files ---
$deployed = 0
$skipped  = 0
$deleted  = 0
$deployedDests = @()

foreach ($pair in $allPairs) {
    if (-not (Test-Path $pair.Source)) {
        Say "[SKIP] $($pair.Label) (not in repo)" 'Yellow'
        $skipped++
        continue
    }

    $deployedDests += $pair.Dest

    $content = (Get-Content -Path $pair.Source -Raw -Encoding UTF8) -replace '\{\{USERNAME\}\}', $username

    $unchanged = (Test-Path $pair.Dest) -and
                 ((Get-Content -Path $pair.Dest -Raw -Encoding UTF8) -eq $content)

    if ($unchanged) {
        Say "[SAME] $($pair.Label)" 'DarkGray'
    } elseif ($DryRun) {
        Say "[OK]   $($pair.Label) -> $($pair.Dest)" 'Green' -Plan
    } else {
        Write-TextFile -Path $pair.Dest -Content $content
        Say "[OK]   $($pair.Label) -> $($pair.Dest)" 'Green'
    }
    $deployed++
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
        $backupPath = Join-Path $backupDir ("pruned\" + (Split-Path -Leaf $stale))
        $backupParent = Split-Path -Parent $backupPath
        if (-not (Test-Path $backupParent)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
        Copy-Item $stale $backupPath -Force
        $backupEntries += [ordered]@{ Label = "pruned\" + (Split-Path -Leaf $stale); Dest = $stale }
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

Write-Host ""
Say "Deployed $deployed files, skipped $skipped, pruned $deleted." 'Cyan' -Plan

# --- PowerShell profiles: additive, and BOTH editions ------------------------
# Windows PowerShell 5.1 and PowerShell 7+ read different profile paths. Wiring only
# one leaves the claude-* functions undefined in the other, which is silent: deploy
# reports success and the functions simply do not exist. So inject into every profile
# path we can find, and never rewrite anything outside our markers.
Write-Host ""
Say "PowerShell profiles (dot-source claude-functions.ps1):" 'Cyan'
foreach ($profilePath in @(Get-ProfilePaths)) {
    $result = Add-ClaudeProfileBlock -Path $profilePath -DryRun:$DryRun -BackupDir $backupDir
    $color = switch ($result) {
        'unchanged'    { 'DarkGray' }
        'would-add'    { 'Green' }
        'would-update' { 'Green' }
        default        { 'Green' }
    }
    Say ("  [{0,-12}] {1}" -f $result, $profilePath) $color
}

# --- Reminders: encrypted secret store (DPAPI, per-user/per-machine) --------
# These .enc files cannot be carried between machines; each machine re-encrypts its
# own secrets locally with Set-Secret.ps1. Registry lives in secrets.json so the
# scripts stay identical across the private and public repos.
$secretsRegistry = Join-Path $repoRoot "secrets.json"
$secretChecks = @()
if (Test-Path $secretsRegistry) {
    try { $secretChecks = @((Get-Content $secretsRegistry -Raw | ConvertFrom-Json).secrets) }
    catch { Say "[WARN] Could not parse secrets.json; skipping secret checks." 'Yellow' }
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
    Write-Host "Dry run complete — nothing was written. Re-run without -DryRun to apply." -ForegroundColor Yellow
} else {
    Write-Host "Restart Claude Code, and open a NEW terminal tab, for changes to take effect." -ForegroundColor Cyan
    Write-Host "Verify with: powershell -ExecutionPolicy Bypass -File `"$repoRoot\doctor.ps1`"" -ForegroundColor Cyan
}
