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

# -ceq: a test that cannot see a case-only difference cannot test the code that must.
function Assert-Eq {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -ceq $Expected) { $script:passed++; Write-Host "  [pass] $Name" -ForegroundColor Green }
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
# (C:\Users\ABCDEF~1\...), and Get-PlanFiles' relative-path arithmetic -- long
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

# --- The account name: tokenized as a path segment only --------------------------
Section "Username tokenization"

# A name with a space and regex metacharacters, and one where '$' would be a
# replacement-string group reference if it were not escaped.
foreach ($u in @('Jane Q. Doe', 'a$1b(c)+')) {
    $live = @(
        "path C:\Users\$u\.claude\x.ps1 here"
        "fwd  c:/users/$u/notes"
        "json `"C:\\Users\\$u\\.claude\\settings.json`""
        "bash /c/Users/$u/x and code ``C:\Users\$u``"
        "clone https://github.com/$u/x.git"
        "mail $u@example.com"
        "prose: ask $u, who wrote it"
        "api   gh api users/$u and https://api.github.com/users/$u"
    ) -join "`n"
    $repo = ConvertTo-RepoTokens -Text $live -ConfigRoot 'Z:/cfg' -Desktop 'Z:/dsk' -UserName $u
    $lines = $repo -split "`n"
    Assert-Eq $lines[0] 'path C:\Users\{{USERNAME}}\.claude\x.ps1 here' "[$u] a backslash path is tokenized"
    Assert-Eq $lines[1] 'fwd  c:/users/{{USERNAME}}/notes' "[$u] a forward-slash path is tokenized, case-insensitively"
    Assert-Eq $lines[2] 'json "C:\\Users\\{{USERNAME}}\\.claude\\settings.json"' "[$u] a JSON-escaped path is tokenized"
    Assert-Eq $lines[3] 'bash /c/Users/{{USERNAME}}/x and code `C:\Users\{{USERNAME}}`' "[$u] git-bash and backtick-quoted paths are tokenized"
    Assert-Eq $lines[4] "clone https://github.com/$u/x.git" "[$u] a GitHub URL survives literally"
    Assert-Eq $lines[5] "mail $u@example.com" "[$u] an email address survives literally"
    Assert-Eq $lines[6] "prose: ask $u, who wrote it" "[$u] a prose mention survives literally"
    Assert-Eq $lines[7] "api   gh api users/$u and https://api.github.com/users/$u" "[$u] GitHub API users/<login> forms are not paths"
    $back = Expand-Tokens -Text $repo -UserName $u -ConfigRoot 'Z:/cfg' -Desktop 'Z:/dsk'
    Assert-Eq $back $live "[$u] deploy(collect(x)) round-trips"
    Assert-True ((ConvertTo-RepoTokens -Text $back -ConfigRoot 'Z:/cfg' -Desktop 'Z:/dsk' -UserName $u) -ceq $repo) "[$u] collect(deploy(repo)) is the repo text again"
    $ok = $true
    try { Assert-NoUserPath -Content $repo -UserName $u -Label 'x' } catch { $ok = $false }
    Assert-True $ok "[$u] tokenized output passes the leak assertion"
}

# Across machines: what one account collected, another account's deploy points home.
$fromA = ConvertTo-RepoTokens -Text 'C:/Users/Jane Q. Doe/.claude/x' -ConfigRoot 'Z:/cfg' -Desktop 'Z:/dsk' -UserName 'Jane Q. Doe'
Assert-Eq (Expand-Tokens -Text $fromA -UserName 'a$1b(c)+' -ConfigRoot 'c' -Desktop 'd') 'C:/Users/a$1b(c)+/.claude/x' "a path collected on one account deploys to another's profile"

# A name that merely starts another account's directory is not that directory.
Assert-Eq (ConvertTo-RepoTokens -Text 'C:\Users\janet\x' -ConfigRoot 'Z:/c' -Desktop 'Z:/d' -UserName 'jane') 'C:\Users\janet\x' "a longer profile name is not tokenized"

# The token in prose -- documenting it -- deploys as itself, so no collect can lose it.
$doc = 'Usernames are parameterized ({{USERNAME}}); the hook runs C:/Users/{{USERNAME}}/x.ps1'
$docOut = Expand-Tokens -Text $doc -UserName 'Jane Q. Doe' -ConfigRoot 'c' -Desktop 'd'
Assert-Eq $docOut 'Usernames are parameterized ({{USERNAME}}); the hook runs C:/Users/Jane Q. Doe/x.ps1' "only the path-shaped token expands"
Assert-Eq (ConvertTo-RepoTokens -Text $docOut -ConfigRoot 'Z:/c' -Desktop 'Z:/d' -UserName 'Jane Q. Doe') $doc "a prose token round-trips"

# The leak assertion fires on a path-shaped near miss the tokenizer refused, and on
# nothing else.
$near = ConvertTo-RepoTokens -Text 'old profile C:\Users\Jane Q. Doe.CORP\x' -ConfigRoot 'Z:/c' -Desktop 'Z:/d' -UserName 'Jane Q. Doe'
Assert-Throws { Assert-NoUserPath -Content $near -UserName 'Jane Q. Doe' -Label 'x' } "a near-miss profile path fails the leak assertion"
$ok = $true
try { Assert-NoUserPath -Content 'https://api.github.com/users/Jane Q. Doe and Jane Q. Doe@example.com' -UserName 'Jane Q. Doe' -Label 'x' } catch { $ok = $false }
Assert-True $ok "a login or email is not a leak"

# --- Manifest validation ------------------------------------------------------
Section "Manifest validation"

$m = Get-ArtifactManifest -ClaudeHome 'X:\ch' -CodexHome 'X:\cx' -AgentsHome 'X:\ag' -DesktopDir 'X:\dt'
$mOk = $true
try { Test-ArtifactManifest -Manifest $m } catch { $mOk = $false }
Assert-True $mOk "the real manifest validates"
$mOk = $true
try { Test-ArtifactManifest -Manifest $m -RepoRoot $repoRoot } catch { $mOk = $false }
Assert-True $mOk "the real manifest validates against the real repo tree"

# workflows-on.json: what 'claude --settings ~/.claude/workflows-on.json' needs to exist.
$wf = @($m.Files | Where-Object { $_.Id -eq 'workflows-on' })
Assert-Eq $wf.Count 1 "workflows-on is a manifest file artifact"
Assert-Eq $wf[0].Repo 'global\workflows-on.json' "workflows-on ships from global\"
Assert-Eq (@($wf[0].Destinations) -join ',') 'X:\ch\workflows-on.json' "workflows-on deploys to ~/.claude/workflows-on.json"
Assert-True ($wf[0].Authority -eq 'installed' -and $wf[0].CollectFrom -eq 'X:\ch\workflows-on.json') "workflows-on is collected from its installed copy"
$wfRepo = Join-Path $repoRoot 'global\workflows-on.json'
Assert-Eq ([System.IO.File]::ReadAllText($wfRepo)) "{ `"enableWorkflows`": true }`n" "the repo file is exactly the overlay, LF-terminated"
Assert-True ((Read-TextFile $wfRepo | ConvertFrom-Json).enableWorkflows -eq $true) "the overlay parses and turns workflows on"

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

# --- Foreign members: another program's entries inside a skills root -----------
Section "Foreign members"

New-Item -ItemType Directory -Path (Join-Path $localSkills 'synced\abc\pptx') -Force | Out-Null
Write-TextFile -Path (Join-Path $localSkills 'synced\.bucket-abc') -Content ''
Write-TextFile -Path (Join-Path $localSkills 'synced\abc\pptx\__init__.py') -Content ''
$claudeArt.ForeignMembers = @('synced')
$claudeFiles2 = @(Select-ArtifactLocalFiles -Artifact $claudeArt -MemberIndex $idx | ForEach-Object RelPath)
Assert-Eq ($claudeFiles2 -join ',') 'private-thing\SKILL.md' "collect never reads a foreign member"

$fm = @{ Files = @(); Dirs = @($claudeArt) }
Assert-True (Test-ForeignDestination -Manifest $fm -Path (Join-Path $localSkills 'synced\abc\pptx\__init__.py')) "a file inside a foreign member is foreign"
Assert-True (Test-ForeignDestination -Manifest $fm -Path (Join-Path $localSkills.ToUpper() 'synced\.bucket-abc')) "the match ignores case, as Windows paths do"
Assert-True (-not (Test-ForeignDestination -Manifest $fm -Path (Join-Path $localSkills 'private-thing\SKILL.md'))) "a managed skill is not foreign"
Assert-True (-not (Test-ForeignDestination -Manifest $fm -Path (Join-Path $localSkills 'synced-notes\SKILL.md'))) "a member merely prefixed by the name is not foreign"
Assert-True (-not (Test-ForeignDestination -Manifest $fm -Path (Join-Path $tmp 'elsewhere\synced\x'))) "outside every destination is not foreign"
Assert-True (Test-ForeignDestination -Manifest $m -Path 'X:\ch\skills\synced\x\SKILL.md') "the real manifest keeps Claude Code's synced cache foreign"

# --- Reading files back: empty is '', not $null ----------------------------------
Section "Empty files"

$empty = Join-Path $tmp 'empty\__init__.py'
Write-TextFile -Path $empty -Content ''
Assert-True ($null -ne (Read-TextFile $empty)) "an empty file reads as a string, not null"
$emptyExpected = Expand-Tokens -Text (Read-TextFile $empty) -UserName 'u' -ConfigRoot 'c' -Desktop 'd'
Assert-True ((Read-TextFile $empty) -eq $emptyExpected) "an empty deployed file matches its empty source"
$bom = Join-Path $tmp 'bom.md'
[System.IO.File]::WriteAllText($bom, 'text', [System.Text.UTF8Encoding]::new($true))
Assert-Eq (Read-TextFile $bom) 'text' "a UTF-8 BOM is dropped, as Get-Content -Encoding UTF8 drops it"

# --- Profile block: an empty profile, and case-only staleness --------------------
Section "Profile block"

$prof = Join-Path $tmp 'profile\Microsoft.PowerShell_profile.ps1'
Write-TextFile -Path $prof -Content ''
Assert-Eq (Add-ClaudeProfileBlock -Path $prof -DryRun) 'would-add' "an empty profile previews an add (it used to throw)"
Assert-Eq (Add-ClaudeProfileBlock -Path $prof) 'added' "an empty profile gets the block"
Assert-True (Test-ClaudeProfileBlock -Path $prof) "the added block is detected"
Assert-Eq (Add-ClaudeProfileBlock -Path $prof) 'unchanged' "a current block is left alone"
$profText = Read-TextFile $prof
Write-TextFile -Path $prof -Content $profText.Replace('Test-Path', 'test-path')
Assert-Eq (Add-ClaudeProfileBlock -Path $prof) 'updated' "a block differing only in case is rewritten"
Assert-True ((Read-TextFile $prof) -ceq $profText) "the rewrite restores the exact block"

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

# A machine that last deployed while the repo still carried a foreign member must be
# able to push after its removal: collect never reads it, so nothing can collide.
$dm.Dirs[0].ForeignMembers = @('synced')
$candF = @(Get-DivergenceCandidates -ChangedRepoPaths @('shared/skills/synced/x/__init__.py', 'shared/skills/website/SKILL.md') -Manifest $dm)
Assert-Eq (@($candF | ForEach-Object RepoPath) -join ',') 'shared/skills/website/SKILL.md' "a foreign member's repo change is not a divergence candidate"

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

$genOut = Join-Path $repo3 'codex\AGENTS.md'
$genText = Read-TextFile $genOut
Write-TextFile -Path $genOut -Content $genText.Replace('shared', 'SHARED')
Assert-Eq (@(Update-GeneratedArtifacts -RepoRoot $repo3 -Manifest $gm -Check))[0].State 'stale' "an output differing only in case reports stale"
Write-TextFile -Path $genOut -Content $genText

# --- Derived agent definition ---------------------------------------------------
Section "Derived agent definition"

$headOk = "---`nname: directed`ndescription: `"worker`"`nmodel: inherit`n---`n`nRole line.`n"
$agent = Build-AgentDefinition -SourceText "###RULES###`r`n- be terse`r`n" -HeadText $headOk `
                               -SourceLabel 'System Prompt.txt' -HeadLabel 'directed-agent\directed.head.md'
Assert-True ($agent.StartsWith("---`n# GENERATED from System Prompt.txt + directed-agent\directed.head.md")) "marker is a YAML comment inside the frontmatter"
Assert-True ($agent -match '(?m)^name: directed$') "frontmatter survives"
Assert-True ($agent -match '(?s)---\n\nRole line\.\n\n###RULES###\n- be terse\n$') "head prose, then the prompt verbatim, LF-only, one trailing newline"
Assert-True ($agent -notmatch "`r") "CRLF source is normalised to LF"
Assert-Throws { Build-AgentDefinition -SourceText 'x' -HeadText "no frontmatter" -SourceLabel 's' -HeadLabel 'h' } "head without a frontmatter block throws"
Assert-Throws { Build-AgentDefinition -SourceText 'x' -HeadText "---`ndescription: d`n---`n" -SourceLabel 's' -HeadLabel 'h' } "head without a name throws"

# Manifest dispatch: Builder = 'agent' builds through Build-AgentDefinition, and a
# missing head fragment is a refusal, not an agent with no frontmatter.
$repo4 = Join-Path $tmp 'repo4'
New-Item -ItemType Directory -Path (Join-Path $repo4 'directed-agent') -Force | Out-Null
Write-TextFile -Path (Join-Path $repo4 'System Prompt.txt') -Content "###RULES###`n- be terse`n"
$agentArt = @{ Id = 'directed-agent'; Repo = 'directed-agent\directed.md'; Destinations = @('X:\ch\agents\directed.md'); Authority = 'repository'
               GeneratedFrom = 'System Prompt.txt'; GeneratedExtra = 'directed-agent\directed.head.md'; Builder = 'agent' }
$am = @{ Files = @($agentArt); Dirs = @() }
Assert-Throws { Update-GeneratedArtifacts -RepoRoot $repo4 -Manifest $am -Check } "agent build without its head fragment throws"
Write-TextFile -Path (Join-Path $repo4 'directed-agent\directed.head.md') -Content $headOk
$r4 = @(Update-GeneratedArtifacts -RepoRoot $repo4 -Manifest $am)
Assert-Eq $r4[0].State 'rebuilt' "agent build writes the output"
Assert-True ((Get-Content (Join-Path $repo4 'directed-agent\directed.md') -Raw) -match '(?m)^# GENERATED') "written agent carries the marker"
Assert-Eq (@(Update-GeneratedArtifacts -RepoRoot $repo4 -Manifest $am -Check))[0].State 'current' "freshly built agent reports current"

# Collection exclusion by a FILE artifact: the generated agent deployed into
# ~/.claude/agents must not be collected back by the claude-agents dir artifact.
$localAgents = Join-Path $tmp 'claude-agents'
New-Item -ItemType Directory -Path $localAgents -Force | Out-Null
Write-TextFile -Path (Join-Path $localAgents 'directed.md') -Content 'generated'
Write-TextFile -Path (Join-Path $localAgents 'file-manager.md') -Content 'mine'
$agentsArt = @{ Id = 'claude-agents'; Repo = 'global\agents'; Destinations = @($localAgents); Authority = 'installed'
                CollectFrom = $localAgents; Filter = '*.md'; Recurse = $false; ExcludeMembersOf = 'directed-agent' }
$idx4 = @{}
$idx4['directed-agent'] = @(Get-ArtifactMembers -RepoRoot $repo4 -Artifact $agentArt)
Assert-Eq ($idx4['directed-agent'] -join ',') 'directed.md' "a file artifact's one member is its own filename"
$collected = @(Select-ArtifactLocalFiles -Artifact $agentsArt -MemberIndex $idx4 | ForEach-Object RelPath)
Assert-Eq ($collected -join ',') 'file-manager.md' "the generated agent is not collected back"
Test-ArtifactManifest -Manifest @{ Files = @($agentArt); Dirs = @($agentsArt) } -RepoRoot $repo4
Assert-True $true "manifest accepts ExcludeMembersOf naming a file artifact"

# ExcludeMembersOf as a list: two generated agents, both kept out of collection.
$workerArt = @{ Id = 'worker-agent'; Repo = 'directed-agent\research-worker.md'; Destinations = @('X:\ch\agents\research-worker.md'); Authority = 'repository'
                GeneratedFrom = 'System Prompt.txt'; GeneratedExtra = 'directed-agent\research-worker.head.md'; Builder = 'agent' }
Write-TextFile -Path (Join-Path $repo4 'directed-agent\research-worker.md') -Content 'generated'
Write-TextFile -Path (Join-Path $localAgents 'research-worker.md') -Content 'generated'
$agentsArt.ExcludeMembersOf = @('directed-agent', 'worker-agent')
$idx4['worker-agent'] = @(Get-ArtifactMembers -RepoRoot $repo4 -Artifact $workerArt)
$collected2 = @(Select-ArtifactLocalFiles -Artifact $agentsArt -MemberIndex $idx4 | ForEach-Object RelPath)
Assert-Eq ($collected2 -join ',') 'file-manager.md' "every listed owner's member is excluded"
Test-ArtifactManifest -Manifest @{ Files = @($agentArt, $workerArt); Dirs = @($agentsArt) } -RepoRoot $repo4
Assert-True $true "manifest accepts an ExcludeMembersOf list"
Assert-Throws {
    Test-ArtifactManifest -Manifest @{ Files = @($agentArt); Dirs = @(@{ Id = 'd'; Repo = 'global\agents'; Destinations = @('X:\a'); Authority = 'installed'
        CollectFrom = 'X:\a'; Filter = '*.md'; Recurse = $false; ExcludeMembersOf = @('directed-agent', 'nope') }) }
} "an unknown id anywhere in the list throws"

# --- Secrets tied to a plugin -----------------------------------------------------
Section "Secrets that serve a plugin"

$setDir = Join-Path $tmp 'settings'
$setOn  = Join-Path $setDir 'on.json'
$setOff = Join-Path $setDir 'off.json'
$setStr = Join-Path $setDir 'string.json'
$setBad = Join-Path $setDir 'bad.json'
$setNone = Join-Path $setDir 'none.json'
Write-TextFile -Path $setOn   -Content '{ "enabledPlugins": { "github@claude-plugins-official": true, "other@x": false } }'
Write-TextFile -Path $setOff  -Content '{ "enabledPlugins": { "github@claude-plugins-official": false } }'
Write-TextFile -Path $setStr  -Content '{ "enabledPlugins": { "github@claude-plugins-official": "true" } }'
Write-TextFile -Path $setBad  -Content '{ "enabledPlugins": '
Write-TextFile -Path $setNone -Content '{ "model": "opus" }'
$ghSecret    = [pscustomobject]@{ name = 'github-token'; purpose = 'p'; plugin = 'github@claude-plugins-official' }
$plainSecret = [pscustomobject]@{ name = 'openrouter-key'; purpose = 'p' }

Assert-True (Test-SecretApplies -Secret $plainSecret -SettingsPath (Join-Path $setDir 'missing.json')) "a secret with no plugin always applies"
Assert-True (Test-SecretApplies -Secret $ghSecret -SettingsPath $setOn) "a plugin secret applies while its plugin is enabled"
Assert-True (-not (Test-SecretApplies -Secret $ghSecret -SettingsPath $setOff)) "a disabled plugin's secret does not apply"
Assert-True (-not (Test-SecretApplies -Secret $ghSecret -SettingsPath $setNone)) "no enabledPlugins at all: does not apply"
Assert-True (-not (Test-SecretApplies -Secret ([pscustomobject]@{ name = 'n'; plugin = 'absent@x' }) -SettingsPath $setOn)) "a plugin missing from enabledPlugins: does not apply"
Assert-True (-not (Test-SecretApplies -Secret $ghSecret -SettingsPath $setStr)) "only a JSON true counts, not the string 'true'"
Assert-True (-not (Test-SecretApplies -Secret $ghSecret -SettingsPath $setBad)) "unreadable settings: does not apply"
Assert-True (-not (Test-SecretApplies -Secret $ghSecret -SettingsPath (Join-Path $setDir 'missing.json'))) "missing settings: does not apply"
Assert-True (Test-SecretApplies -Secret @{ name = 'h'; plugin = 'github@claude-plugins-official' } -SettingsPath $setOn) "a hashtable entry works too"

$registry = @(Get-SecretsRegistry -RepoRoot $repoRoot)
Assert-Eq (@($registry | Where-Object { $_.name -eq 'github-token' })[0].plugin) 'github@claude-plugins-official' "secrets.json ties github-token to the GitHub plugin"
Assert-Eq (@($registry | Where-Object { $_.plugin }).Count) 1 "no other registered secret is tied to a plugin"

# --- .last-deployed ------------------------------------------------------------------
Section "Divergence-guard base"

$gitRepo = Join-Path $tmp 'gitrepo'
New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
Write-TextFile -Path (Join-Path $gitRepo 'f.txt') -Content 'x'
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & git -C $gitRepo init -q 2>$null | Out-Null
    & git -C $gitRepo add f.txt 2>$null | Out-Null
    & git -C $gitRepo -c user.name=t -c user.email=t@example.invalid commit -q -m c0 2>$null | Out-Null
    $headSha = @(& git -C $gitRepo rev-parse HEAD 2>$null)[0]
} finally { $ErrorActionPreference = $previousEap }
Assert-True (Set-LastDeployed -RepoRoot $gitRepo) "Set-LastDeployed writes in a git repo"
Assert-Eq (Read-TextFile (Join-Path $gitRepo '.last-deployed')) $headSha "it records HEAD"
$noGit = Join-Path $tmp 'not-a-repo'
New-Item -ItemType Directory -Path $noGit -Force | Out-Null
$env:GIT_CEILING_DIRECTORIES = $tmp   # however the profile directory is set up, stop here
try {
    Assert-True (-not (Set-LastDeployed -RepoRoot $noGit)) "outside a git repo it writes nothing and says so"
} finally { Remove-Item Env:\GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue }
Assert-True (-not (Test-Path (Join-Path $noGit '.last-deployed'))) "and no file appears"

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
