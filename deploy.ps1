# deploy.ps1 — Deploy repo Claude Code config to local machine with username resolved
# Usage: powershell -ExecutionPolicy Bypass -File deploy.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$username = $env:USERNAME
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Join-Path $env:USERPROFILE "Desktop"

# --- Individual file mappings ---
# NOTE: "System Prompt.txt" and "claude-api.ps1" live directly in the repo root — no deploy needed.
# NOTE: ~/.claude/.*.enc secrets (api-key, github-token, ...) are NEVER deployed
#       (sensitive, DPAPI-encrypted, machine-specific). Missing ones are warned about below.
$fileMappings = @(
    @{ Source = "global\settings.json";                     Dest = "$claudeHome\settings.json" }
    @{ Source = "global\statusline-command.ps1";            Dest = "$claudeHome\statusline-command.ps1" }
    @{ Source = "project-desktop\CLAUDE.md";                 Dest = "$desktopDir\CLAUDE.md" }
    @{ Source = "project-desktop\.claude\settings.local.json"; Dest = "$desktopDir\.claude\settings.local.json" }
    @{ Source = "powershell\Microsoft.PowerShell_profile.ps1"; Dest = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1" }
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
        $files = Get-ChildItem -Path $srcDir -Filter $dir.Filter -File
        foreach ($file in $files) {
            $relSource = Join-Path $dir.SourceDir $file.Name
            $allPairs += @{ Source = $file.FullName; Dest = (Join-Path $dir.DestDir $file.Name); Label = $relSource }
        }
    }
}

# --- Backup existing files ---
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backupDir = Join-Path $repoRoot ".backups\$timestamp"
$backedUp = 0

foreach ($pair in $allPairs) {
    if (Test-Path $pair.Dest) {
        $backupPath = Join-Path $backupDir $pair.Label
        $backupParent = Split-Path -Parent $backupPath
        if (-not (Test-Path $backupParent)) {
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        }
        Copy-Item -Path $pair.Dest -Destination $backupPath -Force
        $backedUp++
    }
}

if ($backedUp -gt 0) {
    Write-Host "Backed up $backedUp existing files to .backups\$timestamp\" -ForegroundColor Cyan
}

# --- Deploy files ---
$deployed = 0
$skipped = 0
$deleted = 0

foreach ($pair in $allPairs) {
    if (-not (Test-Path $pair.Source)) {
        Write-Host "[SKIP] $($pair.Label) (not in repo)" -ForegroundColor Yellow
        $skipped++
        continue
    }

    $content = Get-Content -Path $pair.Source -Raw -Encoding UTF8
    $content = $content -replace '\{\{USERNAME\}\}', $username

    $destDir = Split-Path -Parent $pair.Dest
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($pair.Dest, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[OK]   $($pair.Label) -> $($pair.Dest)" -ForegroundColor Green
    $deployed++
}

# Remove local files that no longer exist in repo
foreach ($dir in $dirMappings) {
    $repoDir = Join-Path $repoRoot $dir.SourceDir
    $localDir = $dir.DestDir
    if (-not (Test-Path $localDir)) { continue }

    $repoNames = @()
    if (Test-Path $repoDir) {
        $repoNames = @(Get-ChildItem -Path $repoDir -Filter $dir.Filter -File | ForEach-Object { $_.Name })
    }

    $localFiles = Get-ChildItem -Path $localDir -Filter $dir.Filter -File
    foreach ($lf in $localFiles) {
        if ($lf.Name -notin $repoNames) {
            # Backup before deleting
            $backupLabel = Join-Path $dir.SourceDir $lf.Name
            $backupPath = Join-Path $backupDir $backupLabel
            $backupParent = Split-Path -Parent $backupPath
            if (-not (Test-Path $backupParent)) {
                New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
            }
            Copy-Item -Path $lf.FullName -Destination $backupPath -Force
            Remove-Item $lf.FullName -Force
            Write-Host "[DEL]  $($dir.DestDir)\$($lf.Name) (removed from repo)" -ForegroundColor Red
            $deleted++
        }
    }
}

Write-Host ""
Write-Host "Deployed $deployed files, skipped $skipped, deleted $deleted." -ForegroundColor Cyan

# --- Reminders: encrypted secret store (DPAPI, per-user/per-machine; intentionally NOT synced) ---
# These .enc files cannot be carried between machines; each machine re-encrypts its own
# secrets locally with Set-Secret.ps1. Warn for any that are missing on this machine.
$secretChecks = @(
    @{ Name = 'api-key';      Purpose = 'Anthropic API mode (claude-api, -sp, -spsp)' }
    @{ Name = 'github-token'; Purpose = 'GitHub MCP server (loaded into env by the PowerShell profile)' }
)
foreach ($s in $secretChecks) {
    $encPath = Join-Path $claudeHome ".$($s.Name).enc"
    if (-not (Test-Path $encPath)) {
        Write-Host ""
        Write-Host "NOTE: encrypted secret '$($s.Name)' not found at $encPath" -ForegroundColor Yellow
        Write-Host "  Needed for: $($s.Purpose)" -ForegroundColor Yellow
        Write-Host "  Create it on this machine (DPAPI, current user only):" -ForegroundColor Yellow
        Write-Host "    & `"$repoRoot\Set-Secret.ps1`" -Name $($s.Name)" -ForegroundColor White
    }
}

if (-not ([Environment]::GetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'User'))) {
    Write-Host ""
    Write-Host "NOTE: ENABLE_TOOL_SEARCH is not set. Setting to 'true' for always-on MCP Tool Search." -ForegroundColor Yellow
    [Environment]::SetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'true', 'User')
    Write-Host "Set ENABLE_TOOL_SEARCH=true (User-level)." -ForegroundColor Green
}

# --- Windows Terminal: ensure Shift+Enter sends a newline (repo-native injection) ---
$wtScript = Join-Path $repoRoot "apply-terminal-keybinding.ps1"
if (Test-Path $wtScript) {
    Write-Host ""
    try {
        & $wtScript
    } catch {
        Write-Host "[WARN] apply-terminal-keybinding.ps1 failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Restart Claude Code for changes to take effect." -ForegroundColor Cyan
