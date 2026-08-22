# tests/run-tests.ps1 -- Unit tests for the sync engine's branching logic.
# Usage: powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
#
# Deliberately dependency-free: the machines carry only the ancient built-in
# Pester 3.4, and a test suite that needs installing before it can run is a test
# suite that does not run. Plain asserts, one process, exit code 0/1.
#
# What lives here is the logic the doctor CANNOT integration-test: manifest
# validation, membership filtering, divergence candidacy, token round trips, and
# the derived-instructions build. Doctor remains the integration test for the
# deployed state itself.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $repoRoot "lib\Common.ps1")

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:passed++; Write-Host "  [pass] $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $Name" -ForegroundColor Red }
}

function Assert-Eq {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -eq $Expected) { $script:passed++; Write-Host "  [pass] $Name" -ForegroundColor Green }
    else {
        $script:failed++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         expected: $Expected" -ForegroundColor DarkGray
        Write-Host "         actual:   $Actual" -ForegroundColor DarkGray
    }
}

function Assert-Throws {
    param([scriptblock]$Block, [string]$Name)
    $threw = $false
    try { & $Block | Out-Null } catch { $threw = $true }
    Assert-True $threw $Name
}

function Section { param([string]$Name) Write-Host ""; Write-Host $Name -ForegroundColor Cyan }

# A scratch area for filesystem-backed tests, removed at the end. NOT under
# $env:TEMP: on Windows PowerShell 5.1 that expands to an 8.3 short path
# (C:\Users\JOHNPE~1\...), and Get-PlanFiles' relative-path arithmetic -- long
# FullName minus short root length -- then slices at the wrong offset. USERPROFILE
# is always the long form.
$tmp = Join-Path $env:USERPROFILE (".config-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {

# --- Token round trip ---------------------------------------------------------
Section "Token round trip"

$cfg = 'C:/Users/Someone/Desktop/claude-config'
$dsk = 'C:/Users/Someone/Desktop'

$fwd = "run $cfg/Get-Secret.ps1 then look in $dsk/notes"
$tok = ConvertTo-RepoTokens -Text $fwd -ConfigRoot $cfg -Desktop $dsk
Assert-Eq $tok 'run {{CONFIG_ROOT}}/Get-Secret.ps1 then look in {{DESKTOP}}/notes' "forward slashes tokenize"

$back = "run $($cfg.Replace('/', '\'))\x.ps1 and $($dsk.Replace('/', '\'))\y"
$tok2 = ConvertTo-RepoTokens -Text $back -ConfigRoot $cfg -Desktop $dsk
Assert-Eq $tok2 'run {{CONFIG_ROOT}}\x.ps1 and {{DESKTOP}}\y' "backslash spelling tokenizes too"

# The ordering trap: the Desktop is a PREFIX of the config root. Tokenizing Desktop
# first would leave '{{DESKTOP}}/claude-config' and the longer token would never match.
Assert-True ($tok -notmatch '\{\{DESKTOP\}\}/claude-config') "CONFIG_ROOT wins over its DESKTOP prefix"

$rt = Expand-Tokens -Text $tok -UserName 'Someone' -ConfigRoot $cfg -Desktop $dsk
Assert-Eq $rt $fwd "expand(tokenize(x)) round-trips"

# --- Manifest validation ------------------------------------------------------
Section "Manifest validation"

$m = Get-ArtifactManifest -ClaudeHome 'X:\ch' -CodexHome 'X:\cx' -AgentsHome 'X:\ag' -DesktopDir 'X:\dt'
$mOk = $true
try { Test-ArtifactManifest -Manifest $m } catch { $mOk = $false }
Assert-True $mOk "the real manifest validates"

Assert-Throws {
    Test-ArtifactManifest -Manifest @{
        Files = @(
            @{ Id = 'a'; Repo = 'r\a'; Destinations = @('X:\a'); Authority = 'installed'; CollectFrom = 'X:\a' }
            @{ Id = 'a'; Repo = 'r\b'; Destinations = @('X:\b'); Authority = 'installed'; CollectFrom = 'X:\b' }
        ); Dirs = @()
    }
} "duplicate ids throw"

Assert-Throws {
    Test-ArtifactManifest -Manifest @{
        Files = @(@{ Id = 'a'; Repo = 'r\a'; Destinations = @('X:\a'); Authority = 'installed' }); Dirs = @()
    }
} "installed without CollectFrom throws"

Assert-Throws {
    Test-ArtifactManifest -Manifest @{
        Files = @(@{ Id = 'a'; Repo = 'r\a'; Destinations = @('X:\a'); Authority = 'installed'; CollectFrom = 'X:\other' }); Dirs = @()
    }
} "CollectFrom outside Destinations throws"

Assert-Throws {
    Test-ArtifactManifest -Manifest @{
        Files = @(@{ Id = 'a'; Repo = 'r\a'; Destinations = @('X:\a'); Authority = 'repository'; CollectFrom = 'X:\a' }); Dirs = @()
    }
} "repository authority with CollectFrom throws"

Assert-Throws {
    Test-ArtifactManifest -Manifest @{
        Files = @(); Dirs = @(
            @{ Id = 'a'; Repo = 'r\a'; Destinations = @('X:\a'); Authority = 'installed'; CollectFrom = 'X:\a'; ExcludeMembersOf = 'nope' }
        )
    }
} "ExcludeMembersOf naming an unknown artifact throws"

# --- Membership: shared vs claude-only vs codex-only --------------------------
Section "Membership filtering"

# repo: shared\skills\website exists; local claude tree holds website AND a private one.
$repo2 = Join-Path $tmp 'repo'
$localSkills = Join-Path $tmp 'claude-skills'
New-Item -ItemType Directory -Path (Join-Path $repo2 'shared\skills\website') -Force | Out-Null
Write-TextFile -Path (Join-Path $repo2 'shared\skills\website\SKILL.md') -Content 'shared'
New-Item -ItemType Directory -Path (Join-Path $localSkills 'website') -Force | Out-Null
Write-TextFile -Path (Join-Path $localSkills 'website\SKILL.md') -Content 'shared'
New-Item -ItemType Directory -Path (Join-Path $localSkills 'private-thing') -Force | Out-Null
Write-TextFile -Path (Join-Path $localSkills 'private-thing\SKILL.md') -Content 'mine'

$sharedArt = @{ Id = 'shared-skills'; Repo = 'shared\skills'; Destinations = @($localSkills); Authority = 'installed'
                CollectFrom = $localSkills; Filter = '*'; Recurse = $true; MembersFromRepo = $true }
$claudeArt = @{ Id = 'claude-skills'; Repo = 'global\skills'; Destinations = @($localSkills); Authority = 'installed'
                CollectFrom = $localSkills; Filter = '*'; Recurse = $true; ExcludeMembersOf = 'shared-skills' }

$idx = @{}
$idx['shared-skills'] = @(Get-ArtifactMembers -RepoRoot $repo2 -Artifact $sharedArt)
$idx['claude-skills'] = @(Get-ArtifactMembers -RepoRoot $repo2 -Artifact $claudeArt)

Assert-Eq ($idx['shared-skills'] -join ',') 'website' "repo decides shared membership"

$sharedFiles = @(Select-ArtifactLocalFiles -Artifact $sharedArt -MemberIndex $idx | ForEach-Object RelPath)
Assert-Eq ($sharedFiles -join ',') 'website\SKILL.md' "shared collect sees only its members"

$claudeFiles = @(Select-ArtifactLocalFiles -Artifact $claudeArt -MemberIndex $idx | ForEach-Object RelPath)
Assert-Eq ($claudeFiles -join ',') 'private-thing\SKILL.md' "claude collect excludes shared members"

# Overlap detection: the same member owned by two artifacts sharing a destination.
New-Item -ItemType Directory -Path (Join-Path $repo2 'global\skills\website') -Force | Out-Null
Write-TextFile -Path (Join-Path $repo2 'global\skills\website\SKILL.md') -Content 'dupe'
Assert-Throws {
    Test-ArtifactManifest -Manifest @{ Files = @(); Dirs = @($sharedArt, $claudeArt) } -RepoRoot $repo2
} "one skill owned by two artifacts sharing a destination throws"
Remove-Item (Join-Path $repo2 'global') -Recurse -Force

# --- Divergence candidacy -----------------------------------------------------
Section "Divergence candidacy"

$dm = @{
    Files = @(
        @{ Id = 'memory'; Repo = 'global\CLAUDE.md'; Destinations = @('X:\ch\CLAUDE.md'); Authority = 'installed'; CollectFrom = 'X:\ch\CLAUDE.md' }
        @{ Id = 'gen';    Repo = 'codex\AGENTS.md';  Destinations = @('X:\cx\AGENTS.md'); Authority = 'repository' }
    )
    Dirs = @(
        @{ Id = 'skills'; Repo = 'shared\skills'; Destinations = @('X:\ch\skills'); Authority = 'installed'
           CollectFrom = 'X:\ch\skills'; Filter = '*'; Recurse = $true }
    )
}
$changed = @('global/CLAUDE.md', 'codex/AGENTS.md', 'shared/skills/website/SKILL.md', 'README.md')
$cand = @(Get-DivergenceCandidates -ChangedRepoPaths $changed -Manifest $dm)

Assert-Eq $cand.Count 2 "two candidates: the installed file and the dir member"
Assert-True (@($cand | Where-Object { $_.Id -eq 'memory' }).Count -eq 1) "changed installed file is a candidate"
Assert-True (@($cand | Where-Object { $_.Id -eq 'gen' }).Count -eq 0) "repository-authoritative change is NOT a candidate"
$skillCand = @($cand | Where-Object { $_.Id -eq 'skills' })[0]
Assert-Eq $skillCand.LocalPath 'X:\ch\skills\website\SKILL.md' "dir candidate maps to the CollectFrom path"

# --- Derived instructions build ------------------------------------------------
Section "Derived instructions build"

$src = @"
# Memory

Shared fact one.

<!-- claude-only -->
## Claude section
Claude-only fact.
<!-- /claude-only -->

Shared fact two.
"@

$built = Build-DerivedInstructions -SourceText $src -ExtraText "## Extra`nCodex fact." -SourceLabel 'global\CLAUDE.md' -ExtraLabel 'codex\AGENTS.extra.md'
Assert-True ($built -match 'Shared fact one') "shared content survives"
Assert-True ($built -match 'Shared fact two') "content after the block survives"
Assert-True ($built -notmatch 'Claude-only fact') "claude-only content is stripped"
Assert-True ($built -match 'Codex fact') "extra fragment is appended"
Assert-True ($built -match 'GENERATED from global\\CLAUDE\.md') "header names the source"

Assert-Throws {
    Build-DerivedInstructions -SourceText "a`n<!-- claude-only -->`nb" -SourceLabel 'x'
} "unbalanced markers throw"

Assert-Throws {
    Build-DerivedInstructions -SourceText "<!-- claude-only --><!-- claude-only -->x<!-- /claude-only --><!-- /claude-only -->" -SourceLabel 'x'
} "nested markers throw"

# --- Update-GeneratedArtifacts against a temp repo ------------------------------
Section "Generated artifacts"

$repo3 = Join-Path $tmp 'repo3'
New-Item -ItemType Directory -Path (Join-Path $repo3 'codex') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $repo3 'global') -Force | Out-Null
Write-TextFile -Path (Join-Path $repo3 'global\CLAUDE.md') -Content "shared`n<!-- claude-only -->secret<!-- /claude-only -->`n"
Write-TextFile -Path (Join-Path $repo3 'codex\AGENTS.extra.md') -Content "extra"
$gm = @{
    Files = @(
        @{ Id = 'gen'; Repo = 'codex\AGENTS.md'; Destinations = @('X:\cx\AGENTS.md'); Authority = 'repository'
           GeneratedFrom = 'global\CLAUDE.md'; GeneratedExtra = 'codex\AGENTS.extra.md' }
    ); Dirs = @()
}

$r1 = @(Update-GeneratedArtifacts -RepoRoot $repo3 -Manifest $gm -Check)
Assert-Eq $r1[0].State 'stale' "missing output reports stale under -Check"

$r2 = @(Update-GeneratedArtifacts -RepoRoot $repo3 -Manifest $gm)
Assert-Eq $r2[0].State 'rebuilt' "build writes the output"
Assert-True ((Get-Content (Join-Path $repo3 'codex\AGENTS.md') -Raw) -notmatch 'secret') "output carries no claude-only content"

$r3 = @(Update-GeneratedArtifacts -RepoRoot $repo3 -Manifest $gm -Check)
Assert-Eq $r3[0].State 'current' "freshly built output reports current"

} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Summary --------------------------------------------------------------------
Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "=== $script:failed failed, $script:passed passed ===" -ForegroundColor Red
    exit 1
}
Write-Host "=== all $script:passed tests passed ===" -ForegroundColor Green
exit 0
