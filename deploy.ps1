# deploy.ps1 — Deploy repo Claude Code config to local machine with username resolved
# Usage: powershell -ExecutionPolicy Bypass -File deploy.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$username = $env:USERNAME
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Join-Path $env:USERPROFILE "Desktop"

# --- Individual file mappings ---
# NOTE: "System Prompt.txt" and "claude-api.ps1" live directly in the repo root — no deploy needed.
# NOTE: .api-key.enc is NEVER deployed (sensitive, DPAPI-encrypted, machine-specific).
#       If missing locally, a warning is shown below.
$fileMappings = @(
    @{ Source = "global\settings.json";                     Dest = "$claudeHome\settings.json" }
    @{ Source = "global\statusline-command.ps1";            Dest = "$claudeHome\statusline-command.ps1" }
    @{ Source = "project-desktop\CLAUDE.md";                 Dest = "$desktopDir\CLAUDE.md" }
    @{ Source = "project-desktop\.claude\settings.local.json"; Dest = "$desktopDir\.claude\settings.local.json" }
    @{ Source = "powershell\Microsoft.PowerShell_profile.ps1"; Dest = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1" }
)

# --- Directory mappings (all *.md files synced as a unit) ---
$dirMappings = @(
    @{ SourceDir = "global\commands"; DestDir = "$claudeHome\commands"; Filter = "*.md" }
    @{ SourceDir = "global\agents";   DestDir = "$claudeHome\agents";  Filter = "*.md" }
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

# --- Reminders ---
if (-not $env:GITHUB_PERSONAL_ACCESS_TOKEN) {
    Write-Host ""
    Write-Host "NOTE: GITHUB_PERSONAL_ACCESS_TOKEN environment variable is not set." -ForegroundColor Yellow
    Write-Host "The GitHub MCP server will not work until you set it:" -ForegroundColor Yellow
    Write-Host '  [Environment]::SetEnvironmentVariable("GITHUB_PERSONAL_ACCESS_TOKEN", "<your-token>", "User")' -ForegroundColor White
    Write-Host "Then restart your terminal." -ForegroundColor Yellow
}

$apiKeyPath = Join-Path $claudeHome ".api-key.enc"
if (-not (Test-Path $apiKeyPath)) {
    Write-Host ""
    Write-Host "NOTE: Encrypted API key not found at $apiKeyPath" -ForegroundColor Yellow
    Write-Host "API-mode functions (claude-api, claude-api-sp, claude-api-spsp) will not work." -ForegroundColor Yellow
    Write-Host "To set up: encrypt your Anthropic API key with DPAPI and save to that path." -ForegroundColor Yellow
    Write-Host "Example: `$secure = Read-Host 'API key' -AsSecureString; ConvertFrom-SecureString `$secure | Set-Content `$apiKeyPath" -ForegroundColor White
}

if (-not ([Environment]::GetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'User'))) {
    Write-Host ""
    Write-Host "NOTE: ENABLE_TOOL_SEARCH is not set. Setting to 'true' for always-on MCP Tool Search." -ForegroundColor Yellow
    [Environment]::SetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'true', 'User')
    Write-Host "Set ENABLE_TOOL_SEARCH=true (User-level)." -ForegroundColor Green
}

Write-Host ""
Write-Host "Restart Claude Code for changes to take effect." -ForegroundColor Cyan
