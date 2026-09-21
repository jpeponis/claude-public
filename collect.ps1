# collect.ps1 -- Collect local agent config (Claude + Codex) into the repo with the
# username parameterized.
# Usage:
#   powershell -ExecutionPolicy Bypass -File collect.ps1
#   powershell -ExecutionPolicy Bypass -File collect.ps1 -Force   # skip the divergence guard
#
# What gets collected, and what is deliberately left out, is described once in
# Get-ArtifactManifest (lib\Common.ps1) and shared with deploy.ps1 and doctor.ps1.
# Only installed-authoritative artifacts are collected; repository-authoritative
# ones (the generated AGENTS.md files) are rebuilt from their sources at the end.

[CmdletBinding()]
param(
    # Skip the multi-machine divergence guard. Only for the case the guard names:
    # you have looked at the conflicting artifact and this machine's copy is the one
    # that should win.
    [switch]$Force
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
$manifest   = Get-ArtifactManifest -ClaudeHome $claudeHome -CodexHome $codexHome -AgentsHome $agentsHome -DesktopDir $desktopDir
Test-ArtifactManifest -Manifest $manifest -RepoRoot $repoRoot

# --- Divergence guard: do not silently overwrite another machine's work -------
# push runs pull -> collect -> commit. On a machine whose DEPLOYED tree is stale, the
# pull brings down another machine's newer files and this collect would immediately
# overwrite them with the old installed copies -- git then sees a clean, plausible
# commit, not a conflict. deploy.ps1 records the commit it deployed in .last-deployed
# (machine-local, untracked); any managed repo path that changed between that commit
# and HEAD while ALSO disagreeing with this machine's installed copy is exactly that
# collision, and collecting through it is data loss.
#
# The fix the message prescribes is deploy (take the repo's newer version), because
# that is almost always right. -Force is for the deliberate exception.
$lastDeployedPath = Join-Path $repoRoot '.last-deployed'
if (-not $Force -and (Test-Path $lastDeployedPath)) {
    $base = (Get-Content $lastDeployedPath -Raw -Encoding UTF8).Trim()
    $changed = @()
    $gitOk = $false
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $changed = @(& git -C $repoRoot diff --name-only "$base" HEAD 2>$null | Where-Object { $_ })
        if ($LASTEXITCODE -eq 0) { $gitOk = $true }
    } catch { }
    finally { $ErrorActionPreference = $previousEap }

    if (-not $gitOk) {
        Write-Host "[WARN] divergence guard: cannot diff against last-deployed commit $base (rebased or gc'd?); proceeding without it" -ForegroundColor Yellow
    } elseif ($changed.Count -gt 0) {
        $conflicts = @()
        foreach ($c in (Get-DivergenceCandidates -ChangedRepoPaths $changed -Manifest $manifest)) {
            $repoPath  = Join-Path $repoRoot ($c.RepoPath.Replace('/', '\'))
            $repoHas   = Test-Path $repoPath
            $localHas  = Test-Path $c.LocalPath
            if ($repoHas -and $localHas) {
                $expected = Expand-Tokens -Text (Read-TextFile $repoPath) `
                                          -UserName $username -ConfigRoot $configRoot -Desktop $desktopTok
                if ((Read-TextFile $c.LocalPath) -ne $expected) {
                    $conflicts += "$($c.RepoPath) (repo and installed copies both changed)"
                }
            } elseif ($repoHas) {
                $conflicts += "$($c.RepoPath) (new in repo, not yet deployed here -- collect would delete it)"
            } elseif ($localHas) {
                $conflicts += "$($c.RepoPath) (deleted in repo, still installed here -- collect would resurrect it)"
            }
        }
        if ($conflicts.Count -gt 0) {
            Write-Host ""
            Write-Host "REFUSING to collect: the repo moved past this machine's last deploy, and these" -ForegroundColor Red
            Write-Host "managed artifacts disagree with the installed copies:" -ForegroundColor Red
            foreach ($x in $conflicts) { Write-Host "  $x" -ForegroundColor Red }
            Write-Host ""
            Write-Host "Run deploy.ps1 first to take the repo's version (your copy is backed up)," -ForegroundColor DarkGray
            Write-Host "or re-run collect.ps1 -Force if this machine's copy should deliberately win." -ForegroundColor DarkGray
            exit 1
        }
    }
}

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
    # machine-specific under every reading. The slash-spelling and ordering rules live
    # with the function, beside Expand-Tokens, so the two directions round-trip.
    $content = ConvertTo-RepoTokens -Text $content -ConfigRoot $configRoot -Desktop $desktopTok

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

# Membership is computed ONCE, against the repo tree as it stood before this run,
# so every artifact filters against the same snapshot regardless of processing order:
# a shared skill deleted locally (and therefore from shared\skills below) must still
# be excluded from claude-skills in the same run, not re-collected there.
$memberIndex = @{}
# Files too, not only Dirs: an ExcludeMembersOf may name a file artifact (the generated
# directed agent, deployed into the same directory claude-agents collects from), and its
# one member is its own filename.
foreach ($owner in (@($manifest.Dirs) + @($manifest.Files))) {
    $memberIndex[$owner.Id] = @(Get-ArtifactMembers -RepoRoot $repoRoot -Artifact $owner)
}

# Process individual files. Repository-authoritative artifacts are never collected --
# the generated AGENTS.md files are rebuilt from their sources at the end of this run.
foreach ($map in $manifest.Files) {
    if ($map.Authority -ne 'installed') { continue }
    Copy-Parameterized -SrcPath $map.CollectFrom -DestPath (Join-Path $repoRoot $map.Repo) -Label $map.Repo
}

# Process directories
foreach ($dir in $manifest.Dirs) {
    if ($dir.Authority -ne 'installed') { continue }
    if (-not (Test-Path $dir.CollectFrom)) {
        if (-not $dir.Optional) { Write-Host "[SKIP] $($dir.CollectFrom) (directory not found)" -ForegroundColor Yellow }
        continue
    }
    $files = Select-ArtifactLocalFiles -Artifact $dir -MemberIndex $memberIndex
    $localRel = @($files | ForEach-Object { $_.RelPath })
    foreach ($file in $files) {
        $relDest = Join-Path $dir.Repo $file.RelPath
        Copy-Parameterized -SrcPath $file.FullName -DestPath (Join-Path $repoRoot $relDest) -Label $relDest
    }

    # Remove repo files that no longer exist locally. Compared on the path relative to
    # the set root, not the filename: every skill's file is named SKILL.md, so a
    # name-only comparison would consider all of them the same file.
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

# --- Rebuild generated artifacts from their freshly collected sources ---------
# After collection so the derived AGENTS.md files always track the CLAUDE.md content
# that was just brought in. These outputs are repository-authoritative: they deploy
# outward, and editing one in place is reported by doctor rather than adopted here.
foreach ($g in (Update-GeneratedArtifacts -RepoRoot $repoRoot -Manifest $manifest)) {
    if ($g.State -eq 'rebuilt') {
        Write-Host "[GEN]  $($g.Label) (rebuilt from sources)" -ForegroundColor Green
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
