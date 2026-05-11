# collect.ps1 — Collect local Claude Code config into repo with username parameterized
# Usage: powershell -ExecutionPolicy Bypass -File collect.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$username = $env:USERNAME
$escapedUsername = [regex]::Escape($username)
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Join-Path $env:USERPROFILE "Desktop"

# --- Individual file mappings ---
# NOTE: "System Prompt.txt" and "claude-api.ps1" live directly in the repo root — no collect needed.
# NOTE: .api-key.enc is NEVER collected (sensitive, DPAPI-encrypted, machine-specific).
$fileMappings = @(
    @{ Source = "$claudeHome\settings.json";              Dest = "global\settings.json" }
    @{ Source = "$claudeHome\statusline-command.ps1";     Dest = "global\statusline-command.ps1" }
    @{ Source = "$desktopDir\CLAUDE.md";                   Dest = "project-desktop\CLAUDE.md" }
    @{ Source = "$desktopDir\.claude\settings.local.json"; Dest = "project-desktop\.claude\settings.local.json" }
    @{ Source = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"; Dest = "powershell\Microsoft.PowerShell_profile.ps1" }
)

# --- Directory mappings (all *.md files synced as a unit) ---
$dirMappings = @(
    @{ SourceDir = "$claudeHome\commands"; DestDir = "global\commands"; Filter = "*.md" }
    @{ SourceDir = "$claudeHome\agents";   DestDir = "global\agents";  Filter = "*.md" }
)

$collected = 0
$skipped = 0

# Helper: read, parameterize username, and write a single file
function Copy-Parameterized {
    param([string]$SrcPath, [string]$DestPath, [string]$Label)

    if (-not (Test-Path $SrcPath)) {
        Write-Host "[SKIP] $Label (not found)" -ForegroundColor Yellow
        $script:skipped++
        return
    }

    $content = Get-Content -Path $SrcPath -Raw -Encoding UTF8
    $content = $content -replace $escapedUsername, '{{USERNAME}}'

    $destDir = Split-Path -Parent $DestPath
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($DestPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[OK]   $Label" -ForegroundColor Green
    $script:collected++
}

# Process individual files
foreach ($map in $fileMappings) {
    Copy-Parameterized -SrcPath $map.Source -DestPath (Join-Path $repoRoot $map.Dest) -Label $map.Dest
}

# Process directories
foreach ($dir in $dirMappings) {
    if (-not (Test-Path $dir.SourceDir)) {
        Write-Host "[SKIP] $($dir.SourceDir) (directory not found)" -ForegroundColor Yellow
        continue
    }
    $files = Get-ChildItem -Path $dir.SourceDir -Filter $dir.Filter -File
    $localNames = @($files | ForEach-Object { $_.Name })
    foreach ($file in $files) {
        $relDest = Join-Path $dir.DestDir $file.Name
        Copy-Parameterized -SrcPath $file.FullName -DestPath (Join-Path $repoRoot $relDest) -Label $relDest
    }

    # Remove repo files that no longer exist locally
    $repoDir = Join-Path $repoRoot $dir.DestDir
    if (Test-Path $repoDir) {
        $repoFiles = Get-ChildItem -Path $repoDir -Filter $dir.Filter -File
        foreach ($rf in $repoFiles) {
            if ($rf.Name -notin $localNames) {
                Remove-Item $rf.FullName -Force
                Write-Host "[DEL]  $(Join-Path $dir.DestDir $rf.Name)" -ForegroundColor Red
            }
        }
    }
}

Write-Host ""
Write-Host "Collected $collected files, skipped $skipped." -ForegroundColor Cyan

# Verify no real username leaked into repo files
$leaks = Get-ChildItem -Path $repoRoot -Recurse -File |
    Where-Object { $_.FullName -notlike "*\.git\*" -and $_.FullName -notlike "*\.backups\*" -and $_.Name -ne "README.md" } |
    Select-String -Pattern $escapedUsername -SimpleMatch
if ($leaks) {
    Write-Host ""
    Write-Host "WARNING: Username '$username' still found in these repo files:" -ForegroundColor Red
    $leaks | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" -ForegroundColor Red }
} else {
    Write-Host "Verified: no instances of '$username' in repo files." -ForegroundColor Green
}
