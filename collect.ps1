# collect.ps1 -- Collect local Claude Code config into repo with username parameterized
# Usage: powershell -ExecutionPolicy Bypass -File collect.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$username = $env:USERNAME
$escapedUsername = [regex]::Escape($username)
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Get-DesktopPath

# --- Individual file mappings ---
# NOTE: Repo-native files ("System Prompt.txt", lib\, and the launcher / doctor / restore /
#       publish scripts) live in the repo -- no collect needed.
# NOTE: ~/.claude/.*.enc secrets are NEVER collected (sensitive, DPAPI-encrypted,
#       machine-specific). The allowlist below excludes them structurally; the registry
#       of expected secret names lives in secrets.json.
# NOTE: The PowerShell profile is deliberately NOT collected. The shell functions live in
#       claude-functions.ps1, which each profile dot-sources via a managed block that
#       deploy.ps1 injects. Collecting a whole profile would drag in whatever unrelated
#       shell config the user keeps there -- and would only ever capture one of the two
#       profile paths (5.1 vs 7+).
$fileMappings = @(
    @{ Source = "$claudeHome\settings.json";              Dest = "global\settings.json" }
    @{ Source = "$claudeHome\statusline-command.ps1";     Dest = "global\statusline-command.ps1" }
    @{ Source = "$claudeHome\claude-functions.ps1";       Dest = "powershell\claude-functions.ps1" }
    @{ Source = "$desktopDir\CLAUDE.md";                   Dest = "project-desktop\CLAUDE.md" }
    @{ Source = "$desktopDir\.claude\settings.local.json"; Dest = "project-desktop\.claude\settings.local.json" }
)

# --- Directory mappings (each Filter synced as a unit) ---
$dirMappings = @(
    @{ SourceDir = "$claudeHome\commands"; DestDir = "global\commands"; Filter = "*.md" }
    @{ SourceDir = "$claudeHome\agents";   DestDir = "global\agents";  Filter = "*.md" }
    @{ SourceDir = "$desktopDir\.claude\workflows"; DestDir = "project-desktop\.claude\workflows"; Filter = "*.js" }
)

# --- Settings the repo owns, which collect must not overwrite from this machine ---
# A collected file is normally a faithful snapshot of whatever is live. 'model' is the
# exception. It records whichever model the last session happened to be using rather
# than a decision about how this config is set up -- it changed twice in forty minutes
# on the day this was written. Collecting it produces noisy commits, and a later
# /sync-config pull then switches the model out from under whoever is working on the
# other machine.
#
# So the repo's value wins in this direction only: deploy still applies it, which is how
# a new machine gets the intended default. To change the default, edit the repo file.
$repoOwnedKeys = @(
    @{ File = "global\settings.json"; Key = "model" }
)

$collected = 0
$skipped = 0

# The value of a single JSON string key, or $null. Text, not ConvertFrom-Json, because
# the result is spliced straight back into the file below.
function Get-JsonStringValue {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Puts the repo's existing value for one key back into freshly collected content.
# Spliced by index rather than parsed and re-serialized: a ConvertTo-Json round trip
# would reformat and reorder the whole file, burying the real change in every diff.
function Restore-RepoOwnedKey {
    param([string]$Content, [string]$RepoPath, [string]$Key)

    if (-not (Test-Path $RepoPath)) { return $Content }   # first collect: take what is live
    $repoValue = Get-JsonStringValue -Text (Get-Content $RepoPath -Raw -Encoding UTF8) -Key $Key
    if ($null -eq $repoValue) { return $Content }

    $localValue = Get-JsonStringValue -Text $Content -Key $Key
    if ($null -eq $localValue -or $localValue -eq $repoValue) { return $Content }

    $m = [regex]::Match($Content, '("' + [regex]::Escape($Key) + '"\s*:\s*)"[^"]*"')
    if (-not $m.Success) { return $Content }

    Write-Host "       kept repo's $Key = $repoValue (this machine is using $localValue)" -ForegroundColor DarkGray
    return $Content.Substring(0, $m.Index) + $m.Groups[1].Value + '"' + $repoValue + '"' +
           $Content.Substring($m.Index + $m.Length)
}

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

    foreach ($owned in @($repoOwnedKeys | Where-Object { $_.File -eq $Label })) {
        $content = Restore-RepoOwnedKey -Content $content -RepoPath $DestPath -Key $owned.Key
    }

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
