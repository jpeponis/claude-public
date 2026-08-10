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

# The reverse of deploy's {{CONFIG_ROOT}} expansion. Both spellings are collapsed
# because a deployed file may legitimately contain either: Get-ConfigRoot emits the
# forward-slashed form, but a human editing ~/.claude/skills/foo/SKILL.md by hand will
# type whichever their shell showed them. Tokenizing only one of the two would leave
# the other as a hardcoded local path, which is the exact failure this token prevents.
#
# Order matters, and only in this direction: the Desktop is a prefix of the config
# root, so tokenizing it first would leave '{{DESKTOP}}/claude-config' behind and the
# longer token would never match again.
$replacements = @(
    @{ Token = '{{CONFIG_ROOT}}'; Value = (Get-ConfigRoot -RepoRoot $repoRoot) }
    @{ Token = '{{DESKTOP}}';     Value = (Get-DesktopToken) }
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

# --- Files that opt out of username parameterization -------------------------
# The blanket replace below assumes every occurrence of the Windows account name is a
# local path. That is wrong for one class of file: the GitHub login can be the SAME
# STRING as the Windows account name while being a different identity. Tokenizing it
# makes the round trip lossy -- deploy expands the token to whatever the next machine's
# Windows account is, quietly rewriting 'gh --repo <owner>/site' to point at an owner
# that does not exist. (publish.ps1 draws the same distinction for the same reason.)
#
# The GitHub login is not machine-specific, so it needs no token; it needs to be left
# alone. A file declares that by carrying this marker anywhere in its text, in whatever
# comment syntax it already uses:
#
#     <!-- sync-config: username-literal -->
#
# The marker lives in the file rather than in a list here on purpose: this script is
# published to the public repo, and a list would have to name private files. It also
# puts the exemption in front of whoever edits the file next.
$UserNameLiteralMarker = 'sync-config: username-literal'

# The account name inside a path -- 'Users\<name>' -- is the unambiguous case: a hardcoded
# local path, which is a portability bug on any machine whether or not privacy is at stake.
# The bare name on its own is ambiguous; it may be a GitHub owner that has to stay literal.
# Both checks at the bottom of this script are built from this one pattern so that the
# per-file guard and the repo-wide sweep cannot drift apart.
$UserPathPattern = '(?i)users[\\/]' + [regex]::Escape($username)

# An opt-out must not become a way for a real local path to slip through -- an exemption
# that disables the check as well is just a hole. Marked files skip the replace, then get
# a stricter test in its place: a path-shaped occurrence is a hard failure.
function Assert-NoUserPath {
    param([string]$Content, [string]$Label)

    $m = [regex]::Match($Content, $UserPathPattern)
    if ($m.Success) {
        throw "$Label carries the username-literal marker but contains a local path " +
              "('$($m.Value)'). Rewrite the path with `$HOME, or remove the marker."
    }
}

$collected = 0
$skipped = 0
$exempt = @()          # labels, for the report
$exemptPaths = @()     # repo paths the marker actually governed
$collectedPaths = @()  # repo paths this run parameterized, and is therefore answerable for

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

    # Machine paths -> tokens, before the username pass and regardless of any marker.
    # The marker exempts a file from having its ACCOUNT NAME tokenized because that name
    # may be a GitHub login; it says nothing about paths, and a machine path is
    # machine-specific under every reading.
    #
    # Both slash spellings are collapsed because a deployed file may legitimately hold
    # either: deploy writes the forward-slashed form, but a human editing
    # ~/.claude/skills/foo/SKILL.md by hand types whatever their shell showed them.
    # Tokenizing only one would leave the other as a hardcoded local path -- the exact
    # failure these tokens exist to prevent.
    foreach ($r in $replacements) {
        $content = $content -replace [regex]::Escape($r.Value), $r.Token
        $content = $content -replace [regex]::Escape($r.Value.Replace('/', '\')), $r.Token
    }

    $note = ''
    if ($content -match [regex]::Escape($UserNameLiteralMarker)) {
        Assert-NoUserPath -Content $content -Label $Label
        $script:exempt += $Label
        $script:exemptPaths += [System.IO.Path]::GetFullPath($DestPath)
        $note = '  (username left literal by marker)'
    } else {
        $content = $content -replace [regex]::Escape($username), '{{USERNAME}}'
        $script:collectedPaths += [System.IO.Path]::GetFullPath($DestPath)
    }

    foreach ($owned in @($repoOwnedKeys | Where-Object { $_.File -eq $Label })) {
        $content = Restore-RepoOwnedKey -Content $content -RepoPath $DestPath -Key $owned.Key
    }

    Write-TextFile -Path $DestPath -Content $content
    Write-Host "[OK]   $Label$note" -ForegroundColor Green
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
    $files = Get-PlanFiles -Root $dir.Local -Filter $dir.Filter -Recurse $dir.Recurse
    $localRel = @($files | ForEach-Object { $_.RelPath })
    foreach ($file in $files) {
        $relDest = Join-Path $dir.Repo $file.RelPath
        Copy-Parameterized -SrcPath $file.FullName -DestPath (Join-Path $repoRoot $relDest) -Label $relDest
    }

    # Remove repo files that no longer exist locally. Compared on the path relative to
    # the set root, not the filename: every skill's file is named SKILL.md, so a
    # name-only comparison would consider all seven of them the same file.
    $repoDir = Join-Path $repoRoot $dir.Repo
    foreach ($rf in (Get-PlanFiles -Root $repoDir -Filter $dir.Filter -Recurse $dir.Recurse)) {
        if ($rf.RelPath -notin $localRel) {
            Remove-Item $rf.FullName -Force
            Write-Host "[DEL]  $(Join-Path $dir.Repo $rf.RelPath)" -ForegroundColor Red
        }
    }

    # A deleted skill leaves its directory behind. Empty directories are invisible to
    # git, so the repo would look clean while the working tree accumulated husks --
    # and a husk named like a real skill is exactly the thing someone later "restores".
    if ($dir.Recurse -and (Test-Path $repoDir)) {
        Get-ChildItem -LiteralPath $repoDir -Directory -Recurse |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
            ForEach-Object {
                Remove-Item $_.FullName -Force
                Write-Host "[DEL]  $(Join-Path $dir.Repo $_.Name)\ (empty)" -ForegroundColor Red
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
#
# Two checks, because the account name means two different things depending on where it
# sits, and one sweep for both is what made this warning useless.
#
#   1. PARAMETERIZATION. In a file this run just wrote, a bare occurrence means the
#      replace above failed. Mechanical and precise -- so it is scoped to exactly those
#      files, the ones collect is answerable for, minus any the marker governed.
#
#   2. HARDCODED PATH. Anywhere in the repo, 'Users\<name>' is a local path that breaks
#      on the next machine. Unambiguous, so it sweeps everything, marker or no marker.
#
# The version before this swept the whole tree for the bare name and so reported five
# hand-authored files where that string is the GITHUB OWNER and has to stay literal: the
# clone URL in the README, the public repo name, and publish.ps1's own allow-list. It was
# wrong every single time it spoke, which is how a check trains people to skim past it --
# and acting on it would have broken the clone URL and the public-repo scan. Those files
# are hand-authored in the repo and never pass through the parameterizer at all, so this
# script was never in a position to have contaminated them.
#
# What this deliberately does NOT do is police personal identifiers. The repo is private
# and legitimately names personal and employer systems; the public boundary is publish.ps1's
# job, and it already scans for the full name and the personal handle while allowing the
# GitHub login. A second, worse copy of that check here would only add noise.
#
# Marker-governed files are named below rather than passed over in silence: their
# occurrences are the GitHub login by declaration, and an unexplained gap is what would
# tempt the next reader to "fix" them back into a placeholder.
$notParameterized = @()
if ($collectedPaths) {
    $notParameterized = @(Select-String -Path $collectedPaths -Pattern ([regex]::Escape($username)))
}

$hardcodedPaths = @(Get-ChildItem -Path $repoRoot -Recurse -File |
    Where-Object { $_.FullName -notlike "*\.git\*" -and $_.FullName -notlike "*\.backups\*" } |
    Select-String -Pattern $UserPathPattern)

if ($exempt) {
    Write-Host "Username left literal by marker (GitHub login, not a path): $($exempt -join ', ')" -ForegroundColor DarkGray
}

$failures = 0

if ($notParameterized) {
    $failures++
    Write-Host ""
    Write-Host "WARNING: username '$username' survived parameterization in:" -ForegroundColor Red
    $notParameterized | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" -ForegroundColor Red }
    Write-Host "  a collected file should carry the placeholder -- or the marker, if the name is a GitHub login" -ForegroundColor DarkGray
}

if ($hardcodedPaths) {
    $failures++
    Write-Host ""
    Write-Host "WARNING: hardcoded local path in:" -ForegroundColor Red
    $hardcodedPaths | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" -ForegroundColor Red }
    Write-Host "  rewrite with `$HOME or `$env:USERPROFILE -- this path exists on one machine only" -ForegroundColor DarkGray
}

if ($failures -eq 0) {
    Write-Host "Verified: $($collectedPaths.Count) file(s) parameterized, no hardcoded local paths." -ForegroundColor Green
}
