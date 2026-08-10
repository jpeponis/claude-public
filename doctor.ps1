# doctor.ps1 -- Report the actual state of this machine's Claude Code install.
# Usage: powershell -ExecutionPolicy Bypass -File doctor.ps1
#
# Why this exists: deploy.ps1 reports *intent* ("I wrote this file"), which can be
# entirely true while the outcome is still wrong. The motivating case: the repo synced
# only the PowerShell 5.1 profile path, so on a machine defaulting to PowerShell 7 every
# claude-* function was undefined -- and deploy printed [OK] the whole time. This script
# reports *state*, and it checks the same things on every run rather than whatever
# happened to come to mind.
#
# Scope is deliberately capped at invariants deploy.ps1 establishes, plus the toolchain,
# so it only needs changing when deploy.ps1 changes.
#
# Exit code: 0 if nothing failed, 1 if any [FAIL].

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$claudeHome = Join-Path $env:USERPROFILE ".claude"
$desktopDir = Get-DesktopPath
$configRoot = Get-ConfigRoot -RepoRoot $repoRoot
$desktopTok = Get-DesktopToken
$plan       = Get-SyncPlan -ClaudeHome $claudeHome -DesktopDir $desktopDir

$script:fails = 0
$script:warns = 0

function Section { param([string]$Name) Write-Host ""; Write-Host $Name -ForegroundColor Cyan }

function Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')][string]$State,
        [string]$Text,
        [string]$Fix
    )
    $color = switch ($State) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    $tag = switch ($State) { 'OK' { '[ OK ]' } 'WARN' { '[WARN]' } 'FAIL' { '[FAIL]' } }
    Write-Host "  $tag $Text" -ForegroundColor $color
    if ($Fix) { Write-Host "         fix: $Fix" -ForegroundColor DarkGray }
    if ($State -eq 'FAIL') { $script:fails++ }
    if ($State -eq 'WARN') { $script:warns++ }
}

function Get-ExeVersion {
    param([string]$Exe, [string[]]$VersionArgs = @('--version'))
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try { return (& $cmd.Source @VersionArgs 2>&1 | Select-Object -First 1) } catch { return $null }
}

Write-Host "=== Claude Code config doctor ===" -ForegroundColor White
Write-Host "repo: $repoRoot" -ForegroundColor DarkGray

# --- Toolchain --------------------------------------------------------------
Section "Toolchain"

$claudeVer = Get-ExeVersion 'claude'
if ($claudeVer) { Check OK "claude on PATH -- $claudeVer" }
else { Check FAIL "claude not found on PATH" "npm install -g @anthropic-ai/claude-code" }

$nodeVer = Get-ExeVersion 'node'
if (-not $nodeVer) {
    Check FAIL "node not found on PATH" "Install Node.js 22 or newer"
} else {
    $major = 0
    if ($nodeVer -match 'v(\d+)\.') { $major = [int]$Matches[1] }
    if ($major -ge 22) { Check OK "node $nodeVer (>= 22 required)" }
    else { Check FAIL "node $nodeVer is older than the required v22" "Install Node.js 22 or newer" }
}

# --- Settings ---------------------------------------------------------------
Section "Settings"

$globalSettings = Join-Path $claudeHome "settings.json"
if (-not (Test-Path $globalSettings)) {
    Check FAIL "missing $globalSettings" "run deploy.ps1"
} elseif (-not (Test-JsonValid (Get-Content $globalSettings -Raw -Encoding UTF8))) {
    Check FAIL "$globalSettings is not valid JSON" "restore.ps1 -Latest, or re-run deploy.ps1"
} else {
    $s = Get-Content $globalSettings -Raw -Encoding UTF8 | ConvertFrom-Json
    Check OK "global settings.json parses (model=$($s.model), effortLevel=$($s.effortLevel))"
}

$localSettings = Join-Path $desktopDir ".claude\settings.local.json"
if (-not (Test-Path $localSettings)) {
    Check WARN "missing $localSettings" "run deploy.ps1"
} elseif (-not (Test-JsonValid (Get-Content $localSettings -Raw -Encoding UTF8))) {
    Check FAIL "$localSettings is not valid JSON" "restore.ps1 -Latest, or re-run deploy.ps1"
} else {
    Check OK "project settings.local.json parses"
}

# --- Deployed content vs what the repo ships --------------------------------
# The set of things that must be here comes from Get-SyncPlan, the same list
# deploy.ps1 acts on -- so a mapping added to the repo is checked here without
# anyone remembering to update this file. A repo file that never arrived is a
# failure; extra local files are the user's own and are fine.
Section "Deployed content"

foreach ($set in $plan.Dirs) {
    $repoDir = Join-Path $repoRoot $set.Repo
    $repoNames  = @(Get-PlanFiles -Root $repoDir   -Filter $set.Filter -Recurse $set.Recurse | ForEach-Object RelPath)
    $localNames = @(Get-PlanFiles -Root $set.Local -Filter $set.Filter -Recurse $set.Recurse | ForEach-Object RelPath)

    $missing = @($repoNames | Where-Object { $_ -notin $localNames })
    $extra   = @($localNames | Where-Object { $_ -notin $repoNames })
    $extraNote = if ($extra.Count) { " (+$($extra.Count) of your own)" } else { "" }

    if ($repoNames.Count -eq 0) {
        Check WARN "$($set.Name): repo ships none"
    } elseif ($missing.Count -eq 0) {
        Check OK "$($set.Name): $($repoNames.Count)/$($repoNames.Count) from repo deployed$extraNote"
    } else {
        Check FAIL "$($set.Name): $($missing.Count) missing -- $($missing -join ', ')" "run deploy.ps1"
    }
}

# --- Does the deployed copy still MATCH the repo? ---------------------------
# Presence was never the whole question. Editing ~/.claude/commands/foo.md directly
# is the normal way to work on a skill, and nothing announces that the repo now
# disagrees -- until the next deploy silently overwrites the edit (recoverably, into
# .backups\, but only if you know to look). Neither answer is "wrong", so this warns
# and names both directions rather than failing.
$drifted = @()
$deployedPairs = @()
foreach ($map in $plan.Files) {
    $deployedPairs += @{ Repo = (Join-Path $repoRoot $map.Repo); Local = $map.Local; Label = $map.Repo }
}
foreach ($set in $plan.Dirs) {
    foreach ($f in (Get-PlanFiles -Root (Join-Path $repoRoot $set.Repo) -Filter $set.Filter -Recurse $set.Recurse)) {
        $deployedPairs += @{
            Repo  = $f.FullName
            Local = (Join-Path $set.Local $f.RelPath)
            Label = (Join-Path $set.Repo $f.RelPath)
        }
    }
}

foreach ($p in $deployedPairs) {
    if (-not (Test-Path $p.Repo) -or -not (Test-Path $p.Local)) { continue }   # absence reported above
    $expected = Expand-Tokens -Text (Get-Content $p.Repo -Raw -Encoding UTF8) `
                              -UserName $env:USERNAME -ConfigRoot $configRoot -Desktop $desktopTok
    if ((Get-Content $p.Local -Raw -Encoding UTF8) -ne $expected) { $drifted += $p.Label }
}

if ($drifted.Count -eq 0) {
    Check OK "every deployed file matches the repo"
} else {
    Check WARN "$($drifted.Count) deployed file(s) differ from the repo -- $($drifted -join ', ')" "collect.ps1 to keep the local edits, deploy.ps1 to take the repo's"
}

# --- Statusline: does it actually run? --------------------------------------
Section "Statusline"

$slPath = Join-Path $claudeHome "statusline-command.ps1"
if (-not (Test-Path $slPath)) {
    Check WARN "missing $slPath" "run deploy.ps1"
} else {
    try {
        $out = '{}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $slPath 2>&1 | Out-String
        # The statusline emits ANSI colour codes; strip them so this report stays readable.
        $out = ([regex]::Replace($out, "$([char]27)\[[0-9;]*[A-Za-z]", '')).Trim()
        if ($LASTEXITCODE -ne 0) {
            Check FAIL "statusline exited $LASTEXITCODE -- $out" "inspect $slPath"
        } elseif ([string]::IsNullOrWhiteSpace($out)) {
            Check WARN "statusline ran but produced no output" "inspect $slPath"
        } else {
            Check OK "statusline executes -- `"$out`""
        }
    } catch {
        Check FAIL "statusline threw -- $($_.Exception.Message)" "inspect $slPath"
    }
}

# --- Shell functions: the check that catches the silent failure -------------
# Both profile paths must be wired, or the functions exist in only one of the
# user's shells and nothing announces it.
Section "Shell functions"

$fnPath = Join-Path $claudeHome "claude-functions.ps1"
if (Test-Path $fnPath) { Check OK "claude-functions.ps1 deployed to ~/.claude/" }
else { Check FAIL "missing $fnPath" "run deploy.ps1" }

$profilePaths = @(Get-ProfilePaths)
$wired = @()
$unwired = @()
foreach ($p in $profilePaths) {
    $edition = switch -Wildcard ($p) {
        '*\WindowsPowerShell\*' { 'Windows PowerShell 5.1' }
        '*\PowerShell\*'        { 'PowerShell 7+' }
        default                 { 'PowerShell' }
    }
    if (Test-ClaudeProfileBlock -Path $p) {
        $wired += $p
        Check OK "$edition profile sources claude-functions.ps1"
    } else {
        $unwired += $p
        Check FAIL "$edition profile is missing the managed block -- $p" "run deploy.ps1"
    }
}

if ($profilePaths.Count -eq 0) {
    Check FAIL "could not determine any PowerShell profile path"
} elseif ($unwired.Count -eq 0) {
    Check OK "every discovered profile is wired -- the functions exist in whichever shell you open"
}

$term = Get-TerminalDefaultProfile
if ($term) {
    $note = "Windows Terminal opens '$($term.DefaultProfileName)' by default"
    if ($unwired.Count -eq 0) { Check OK $note }
    else { Check WARN "$note -- confirm that shell is one of the wired profiles above" "run deploy.ps1" }
}

# --- Windows Terminal Shift+Enter ------------------------------------------
Section "Windows Terminal"

$wtPaths = @(Get-TerminalSettingsPaths)
if ($wtPaths.Count -eq 0) {
    Check WARN "Windows Terminal settings.json not found (Terminal may not be installed)"
} else {
    foreach ($wt in $wtPaths) {
        $label = $wt.Replace($env:LOCALAPPDATA, '%LOCALAPPDATA%')
        if ((Get-Content $wt -Raw -Encoding UTF8) -match 'User\.sendInput\.ShiftEnterNewline') {
            Check OK "Shift+Enter newline binding present -- $label"
        } else {
            Check WARN "Shift+Enter newline binding absent -- $label" "powershell -File `"$repoRoot\apply-terminal-keybinding.ps1`""
        }
    }
}

# --- Secrets (optional, per-machine, never synced) --------------------------
Section "Secrets (per-machine, never synced)"

$registry = $null
try { $registry = Get-SecretsRegistry -RepoRoot $repoRoot }
catch { Check FAIL "secrets.json is not valid JSON -- $($_.Exception.Message)" }

if ($null -eq $registry) {
    Check WARN "secrets.json not found in repo"
} else {
    # Present is not the same as readable. A file written by an older scheme, or by a
    # different Windows user or machine, sits there looking fine and fails at the
    # moment something needs it -- which is a launcher failing, not a warning. So
    # decrypt each one for real and report what actually happens.
    foreach ($sec in $registry) {
        $encPath = Join-Path $claudeHome ".$($sec.name).enc"
        if (-not (Test-Path $encPath)) {
            Check WARN "$($sec.name) absent -- $($sec.purpose)" "& `"$repoRoot\Set-Secret.ps1`" -Name $($sec.name)"
            continue
        }
        $value = $null
        try { $value = & (Join-Path $repoRoot "Get-Secret.ps1") -Name $sec.name 2>$null } catch { }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Check FAIL "$($sec.name) present but cannot be decrypted -- $($sec.purpose)" "re-encrypt it on this machine: & `"$repoRoot\Set-Secret.ps1`" -Name $($sec.name)"
        } else {
            Check OK "$($sec.name) present and decrypts"
        }
    }
}

# --- Environment ------------------------------------------------------------
Section "Environment"

$ets = [Environment]::GetEnvironmentVariable('ENABLE_TOOL_SEARCH', 'User')
if ($ets) { Check OK "ENABLE_TOOL_SEARCH=$ets (User) -- MCP tool definitions load lazily" }
else { Check WARN "ENABLE_TOOL_SEARCH not set (User)" "run deploy.ps1, which sets it" }

# --- Repo health ------------------------------------------------------------
# Windows PowerShell 5.1 reads a BOM-less script as ANSI, not UTF-8. An em-dash then
# decodes to 'a EUR "' whose last byte is U+201D -- a smart quote, which PowerShell
# treats as a string delimiter. Inside a comment that is harmless; inside a
# double-quoted string it ends the string early and the whole parse collapses.
# Keeping script source pure ASCII sidesteps it in both editions, with or without a BOM.
Section "Repo health"

$nonAscii = @()
Get-ChildItem $repoRoot -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notlike '*\.backups\*' } |
    ForEach-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        if ($text -match '[^\x00-\x7F]') { $nonAscii += $_.FullName.Substring($repoRoot.Length + 1) }
    }

if ($nonAscii.Count -eq 0) {
    Check OK "all repo .ps1 files are pure ASCII (parse identically in PowerShell 5.1 and 7)"
} else {
    Check FAIL "non-ASCII in: $($nonAscii -join ', ')" "replace non-ASCII characters (em-dashes are the usual culprit) with ASCII"
}

# --- Invariants about the CONTENT this repo ships ---------------------------
# Everything above this point checks mechanism: does the file exist, parse, match,
# decrypt. All of it can be green while the shipped content is wrong in ways that
# matter more -- and both checks below are here because it WAS.
#
# Neither of these is hypothetical or stylistic. They are the two defects that
# survived every mechanical check this script already had.
Section "Synced content"

$skillSet = @($plan.Dirs | Where-Object { $_.Name -eq 'skills' })[0]

if (-not $skillSet) {
    Check WARN "no skills set in the sync plan"
} else {
    $skillRoot = Join-Path $repoRoot $skillSet.Repo
    $skillDirs = @()
    if (Test-Path $skillRoot) { $skillDirs = @(Get-ChildItem $skillRoot -Directory) }

    # A skill's `description` is how Claude decides whether to reach for it. When it is
    # absent the listing falls back to the first paragraph of markdown, so a skill whose
    # file opens with a title heading advertises itself as, exactly, that title -- which
    # says nothing about when the skill applies. Such a skill is invocable by name and
    # undiscoverable by the model, and nothing else reports the difference.
    $noDescription = @()
    $noSkillFile   = @()
    foreach ($d in $skillDirs) {
        $skillFile = Join-Path $d.FullName 'SKILL.md'
        if (-not (Test-Path $skillFile)) { $noSkillFile += $d.Name; continue }
        $text = Get-Content $skillFile -Raw -Encoding UTF8
        $fm = [regex]::Match($text, '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
        if (-not $fm.Success -or $fm.Groups[1].Value -notmatch '(?m)^description:\s*\S') {
            $noDescription += $d.Name
        }
    }

    if ($skillDirs.Count -eq 0) {
        Check WARN "repo ships no skills"
    } elseif ($noSkillFile.Count -gt 0) {
        Check FAIL "skill director(ies) with no SKILL.md: $($noSkillFile -join ', ')" "a skill directory without SKILL.md produces no slash command"
    } elseif ($noDescription.Count -gt 0) {
        Check FAIL "skill(s) with no frontmatter description: $($noDescription -join ', ')" "add 'description:' to SKILL.md -- without it Claude only sees the first paragraph"
    } else {
        Check OK "all $($skillDirs.Count) skills declare a description"
    }
}

# The repo path, spelled literally, in a file that gets DEPLOYED. Prose is executed
# here -- a skill saying 'run $HOME/Desktop/claude-config/x.ps1' sends Claude to a path
# that does not exist on any machine with OneDrive Known Folder Move. This is the same
# bug Get-DesktopPath fixed in the .ps1 files, and it lived on in the markdown for
# months precisely because no check looked at prose. {{CONFIG_ROOT}} is the fix; this
# is what keeps it from rotting back.
$literalPathHits = @()
$syncedRepoPaths = @($plan.Files | ForEach-Object { Join-Path $repoRoot $_.Repo })
foreach ($set in $plan.Dirs) {
    $syncedRepoPaths += @(Get-PlanFiles -Root (Join-Path $repoRoot $set.Repo) -Filter $set.Filter -Recurse $set.Recurse |
        ForEach-Object FullName)
}
foreach ($f in ($syncedRepoPaths | Where-Object { $_ -like '*.md' -and (Test-Path $_) })) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        $n++
        if ($line -match '(?i)Desktop[\\/]+claude-(config|scratch)') {
            $literalPathHits += "$($f.Substring($repoRoot.Length + 1)):$n"
        }
    }
}

if ($literalPathHits.Count -eq 0) {
    Check OK "no synced markdown hardcodes a Desktop path (they use {{CONFIG_ROOT}} / {{DESKTOP}})"
} else {
    Check FAIL "literal Desktop path in: $($literalPathHits -join ', ')" "use {{CONFIG_ROOT}} or {{DESKTOP}}, which deploy.ps1 expands per machine"
}

# research-worker.md deliberately carries the same prompt as "System Prompt.txt", so that
# spawned workers hold the same disposition the session does. It is the one duplication
# here kept on purpose -- and a deliberate copy is no less prone to drifting than an
# accidental one, since nothing about editing either file mentions the other.
#
# Checked as a SUBSET rather than an exact match, because the worker legitimately omits
# the opening line, which addresses the session model. Every line the worker DOES carry
# must read the way the system prompt reads it. This catches the drift from either side:
# editing "System Prompt.txt" and forgetting the agent fails just as loudly.
$promptPath = Join-Path $repoRoot 'System Prompt.txt'
$workerPath = Join-Path $repoRoot 'global\agents\research-worker.md'

if (-not (Test-Path $promptPath) -or -not (Test-Path $workerPath)) {
    Check WARN "cannot compare the worker prompt: System Prompt.txt or research-worker.md is missing"
} else {
    $promptLines = @([System.IO.File]::ReadAllLines($promptPath) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $workerAll   = @([System.IO.File]::ReadAllLines($workerPath))
    $fmEnd       = [array]::IndexOf($workerAll, '---', 1)
    $workerLines = @($workerAll[($fmEnd + 1)..($workerAll.Count - 1)] | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $orphans     = @($workerLines | Where-Object { $_ -notin $promptLines })

    if ($fmEnd -lt 1) {
        Check FAIL "research-worker.md has no frontmatter block" "an agent definition needs name/description/tools frontmatter"
    } elseif ($orphans.Count -eq 0) {
        Check OK "research-worker's prompt matches System Prompt.txt ($($workerLines.Count) lines, subset)"
    } else {
        $sample = $orphans[0]
        if ($sample.Length -gt 60) { $sample = $sample.Substring(0, 60) + '...' }
        Check FAIL "research-worker's prompt has drifted from System Prompt.txt in $($orphans.Count) line(s) -- first: `"$sample`"" "reconcile the two; they are the same prompt by design"
    }
}

# --- Summary ----------------------------------------------------------------
Write-Host ""
$summary = "$script:fails failure(s), $script:warns warning(s)"
if ($script:fails -gt 0) {
    Write-Host "=== $summary ===" -ForegroundColor Red
    Write-Host "Warnings are usually fine (optional secrets, uninstalled Terminal). Failures are not." -ForegroundColor DarkGray
    exit 1
} elseif ($script:warns -gt 0) {
    Write-Host "=== healthy -- $summary ===" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "=== all checks passed ===" -ForegroundColor Green
    exit 0
}
