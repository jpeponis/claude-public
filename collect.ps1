# collect.ps1 -- Collect local Claude Code config into repo with username parameterized
# Usage: powershell -ExecutionPolicy Bypass -File collect.ps1
#
# What gets collected, and what is deliberately left out, is described once in
# Get-SyncPlan (lib\Common.ps1) and shared with deploy.ps1 and doctor.ps1.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$username = $env:USERNAME
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Get-DesktopPath
$plan = Get-SyncPlan -ClaudeHome $claudeHome -DesktopDir $desktopDir

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

    # -replace, not String.Replace: this direction must be case-INSENSITIVE, because a
    # local path may spell the username with different casing than $env:USERNAME does
    # (C:\users\jane\... is the same directory as C:\Users\Jane\...). A case-sensitive
    # replace would leave those spellings behind as a real-name leak.
    $content = Get-Content -Path $SrcPath -Raw -Encoding UTF8
    $content = $content -replace [regex]::Escape($username), '{{USERNAME}}'

    foreach ($owned in @($repoOwnedKeys | Where-Object { $_.File -eq $Label })) {
        $content = Restore-RepoOwnedKey -Content $content -RepoPath $DestPath -Key $owned.Key
    }

    Write-TextFile -Path $DestPath -Content $content
    Write-Host "[OK]   $Label" -ForegroundColor Green
    $script:collected++
}

# Process individual files
foreach ($map in $plan.Files) {
    Copy-Parameterized -SrcPath $map.Local -DestPath (Join-Path $repoRoot $map.Repo) -Label $map.Repo
}

# Process directories
foreach ($dir in $plan.Dirs) {
    if (-not (Test-Path $dir.Local)) {
        Write-Host "[SKIP] $($dir.Local) (directory not found)" -ForegroundColor Yellow
        continue
    }
    $files = Get-ChildItem -Path $dir.Local -Filter $dir.Filter -File
    $localNames = @($files | ForEach-Object { $_.Name })
    foreach ($file in $files) {
        $relDest = Join-Path $dir.Repo $file.Name
        Copy-Parameterized -SrcPath $file.FullName -DestPath (Join-Path $repoRoot $relDest) -Label $relDest
    }

    # Remove repo files that no longer exist locally
    $repoDir = Join-Path $repoRoot $dir.Repo
    if (Test-Path $repoDir) {
        $repoFiles = Get-ChildItem -Path $repoDir -Filter $dir.Filter -File
        foreach ($rf in $repoFiles) {
            if ($rf.Name -notin $localNames) {
                Remove-Item $rf.FullName -Force
                Write-Host "[DEL]  $(Join-Path $dir.Repo $rf.Name)" -ForegroundColor Red
            }
        }
    }
}

Write-Host ""
Write-Host "Collected $collected files, skipped $skipped." -ForegroundColor Cyan

# --- Verify no real username leaked into repo files --------------------------
# This is the last thing standing between a real name and a pushed commit, so it has
# to actually run. It did not: the pattern is regex-escaped, and passing an escaped
# pattern to -SimpleMatch searches for the BACKSLASHES too. Any username containing a
# character Regex.Escape touches -- a space is the common one, since Regex.Escape turns
# "First Last" into "First\ Last" -- could therefore never match, and this printed the
# green "Verified: no instances" line no matter what the files contained.
#
# (Note the shape of the bug: it is a check that cannot fail. Prefer wording examples
# around the live username here; this scan cannot tell an illustration from a leak.)
#
# Escaped pattern + regex matching is the correct pairing: it matches the name
# literally AND stays case-insensitive, which -SimpleMatch would also have given up.
$leaks = Get-ChildItem -Path $repoRoot -Recurse -File |
    Where-Object { $_.FullName -notlike "*\.git\*" -and $_.FullName -notlike "*\.backups\*" } |
    Select-String -Pattern ([regex]::Escape($username))
if ($leaks) {
    Write-Host ""
    Write-Host "WARNING: Username '$username' still found in these repo files:" -ForegroundColor Red
    $leaks | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" -ForegroundColor Red }
} else {
    Write-Host "Verified: no instances of '$username' in repo files." -ForegroundColor Green
}
