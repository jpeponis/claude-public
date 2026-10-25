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
$codexHome  = Join-Path $env:USERPROFILE ".codex"
$agentsHome = Join-Path $env:USERPROFILE ".agents"
$desktopDir = Get-DesktopPath
$configRoot = Get-ConfigRoot -RepoRoot $repoRoot
$desktopTok = Get-DesktopToken
$plan       = Get-ArtifactManifest -ClaudeHome $claudeHome -CodexHome $codexHome -AgentsHome $agentsHome -DesktopDir $desktopDir

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

# Strict JSON, the way Claude Code reads its settings files. Common.ps1's Test-JsonValid
# is deliberately lenient (comments, trailing commas) because Windows Terminal's
# settings are JSONC; a settings.json that passes only that test is one Claude Code
# rejects. Default JsonDocumentOptions disallow both. ConvertFrom-Json is not a
# substitute on PowerShell 7, which accepts trailing commas; on 5.1, where
# System.Text.Json does not exist, it is strict about both, so it is the fallback.
function Test-StrictJson {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }
    try {
        if ('System.Text.Json.JsonDocument' -as [type]) {
            ([System.Text.Json.JsonDocument]::Parse($Json, [System.Text.Json.JsonDocumentOptions]::new())).Dispose()
        } else {
            [void]($Json | ConvertFrom-Json)
        }
        return $true
    } catch {
        return $false
    }
}

# One Claude Code settings file: present and strict JSON. $true when it passes; a
# failure has already been reported.
function Test-SettingsFile {
    param([string]$Path, [ValidateSet('WARN', 'FAIL')][string]$IfMissing)
    if (-not (Test-Path -LiteralPath $Path)) { Check $IfMissing "missing $Path" "run deploy.ps1"; return $false }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (Test-StrictJson $raw) { return $true }
    if (Test-JsonValid $raw) {
        Check FAIL "$Path has comments or trailing commas -- fine as JSONC, but Claude Code requires strict JSON" "remove them"
    } else {
        Check FAIL "$Path is not valid JSON" "restore.ps1 -Latest, or re-run deploy.ps1"
    }
    return $false
}

Write-Host "=== Claude Code config doctor ===" -ForegroundColor White
Write-Host "repo: $repoRoot" -ForegroundColor DarkGray

# --- Toolchain --------------------------------------------------------------
Section "Toolchain"

$claudeVer = Get-ExeVersion 'claude'
if ($claudeVer) { Check OK "claude on PATH -- $claudeVer" }
else { Check FAIL "claude not found on PATH" "irm https://claude.ai/install.ps1 | iex   (or: winget install Anthropic.ClaudeCode)" }

# Claude Code here is the native install, which needs no Node. Node matters only to
# npm-installed tools -- Codex CLI's npm launcher is a Node script -- so its absence
# is worth knowing, not a failure.
$nodeVer = Get-ExeVersion 'node'
if ($nodeVer) { Check OK "node $nodeVer on PATH (used by npm-installed tools such as Codex CLI)" }
else { Check WARN "node not found on PATH -- only needed for npm-installed tools such as Codex CLI" "winget install OpenJS.NodeJS.LTS" }

# --- Settings ---------------------------------------------------------------
Section "Settings"

$globalSettings = Join-Path $claudeHome "settings.json"
if (Test-SettingsFile -Path $globalSettings -IfMissing FAIL) {
    $s = Get-Content $globalSettings -Raw -Encoding UTF8 | ConvertFrom-Json
    Check OK "global settings.json parses as strict JSON (model=$($s.model), effortLevel=$($s.effortLevel))"
}

$localSettings = Join-Path $desktopDir ".claude\settings.local.json"
if (Test-SettingsFile -Path $localSettings -IfMissing WARN) {
    Check OK "project settings.local.json parses as strict JSON"
}

# --- Deployed content vs what the repo ships --------------------------------
# The set of things that must be here comes from Get-ArtifactManifest, the same list
# deploy.ps1 acts on -- so a mapping added to the repo is checked here without
# anyone remembering to update this file. A repo file that never arrived is a
# failure; extra local files are the user's own (or another tool's -- Codex ships
# system skills into its own trees) and are reported, never counted as drift.
# Multi-destination artifacts are checked at EVERY destination: the projection
# going missing is precisely the failure a single-destination check cannot see.
Section "Deployed content"

# Top-level entries in a destination directory that NO artifact owns: not a member of
# any dir artifact deploying there, not a file artifact's target, not another
# program's ForeignMembers. Counted per entry because a skill is a directory -- the
# file count used to report Claude Code's own 'synced' cache as 240-odd "unmanaged"
# files, which buried the one or two skills that really are the user's own.
function Get-UnmanagedEntries {
    param([string]$DestRoot, $Set)
    if (-not (Test-Path -LiteralPath $DestRoot)) { return @() }
    $owned = @()
    foreach ($d in @($plan.Dirs | Where-Object { $DestRoot -in @($_.Destinations) })) {
        $owned += @(Get-ArtifactMembers -RepoRoot $repoRoot -Artifact $d)
        $owned += @($d.ForeignMembers | Where-Object { $_ })
    }
    foreach ($f in $plan.Files) {
        foreach ($dest in @($f.Destinations)) {
            if ((Split-Path -Parent $dest) -eq $DestRoot) { $owned += (Split-Path -Leaf $dest) }
        }
    }
    $entries = if ($Set.Recurse) { Get-ChildItem -LiteralPath $DestRoot }
               else { Get-ChildItem -LiteralPath $DestRoot -Filter $Set.Filter -File }
    return @($entries | Where-Object { $_.Name -notin $owned } | ForEach-Object Name)
}

foreach ($set in $plan.Dirs) {
    $repoDir = Join-Path $repoRoot $set.Repo
    $repoNames = @(Get-PlanFiles -Root $repoDir -Filter $set.Filter -Recurse $set.Recurse | ForEach-Object RelPath)

    if ($repoNames.Count -eq 0) {
        if ($set.Optional) { Check OK "$($set.Name): repo ships none (optional set)" }
        else { Check WARN "$($set.Name): repo ships none" }
        continue
    }

    $unit = if ($set.Repo -like '*skills') { 'skill(s)' } else { 'file(s)' }
    foreach ($destRoot in @($set.Destinations)) {
        $localNames = @(Get-PlanFiles -Root $destRoot -Filter $set.Filter -Recurse $set.Recurse | ForEach-Object RelPath)
        $missing = @($repoNames | Where-Object { $_ -notin $localNames })
        $extra   = @(Get-UnmanagedEntries -DestRoot $destRoot -Set $set)
        $extraNote = if ($extra.Count) { " (+$($extra.Count) unmanaged $unit, left alone: $($extra -join ', '))" } else { "" }

        if ($missing.Count -eq 0) {
            Check OK "$($set.Name) -> $destRoot`: $($repoNames.Count)/$($repoNames.Count) deployed$extraNote"
        } else {
            Check FAIL "$($set.Name) -> $destRoot`: $($missing.Count) missing -- $($missing -join ', ')" "run deploy.ps1"
        }
    }
}

# Single-file artifacts (memory files, settings, generated agents and AGENTS.md, the
# launchers), at every destination. The dir loop above never saw these, so a deployed
# CLAUDE.md or AGENTS.md could vanish while every line stayed green.
$fileDests = 0
$fileMissing = 0
foreach ($map in $plan.Files) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $map.Repo))) {
        $fileMissing++
        Check FAIL "$($map.Id): the repo has no $($map.Repo), so deploy has nothing to install" "restore it in the repo, or remove the artifact from Get-ArtifactManifest"
        continue
    }
    foreach ($dest in @($map.Destinations)) {
        $fileDests++
        if (-not (Test-Path -LiteralPath $dest)) {
            $fileMissing++
            Check FAIL "$($map.Id) -> $dest`: missing" "run deploy.ps1"
        }
    }
}
if ($fileMissing -eq 0) { Check OK "single-file artifacts: $fileDests/$fileDests destinations present" }

# --- Does the deployed copy still MATCH the repo? ---------------------------
# Presence was never the whole question. Editing a deployed file directly is the
# normal way to work on a skill, and nothing announces that the repo now
# disagrees -- until the next deploy silently overwrites the edit (recoverably, into
# .backups\, but only if you know to look). Neither answer is "wrong", so this warns
# and names both directions rather than failing.
$drifted = @()
$deployedPairs = @()
foreach ($map in $plan.Files) {
    foreach ($dest in @($map.Destinations)) {
        $deployedPairs += @{ Repo = (Join-Path $repoRoot $map.Repo); Local = $dest; Label = "$($map.Repo) -> $dest" }
    }
}
foreach ($set in $plan.Dirs) {
    foreach ($f in (Get-PlanFiles -Root (Join-Path $repoRoot $set.Repo) -Filter $set.Filter -Recurse $set.Recurse)) {
        foreach ($destRoot in @($set.Destinations)) {
            $deployedPairs += @{
                Repo  = $f.FullName
                Local = (Join-Path $destRoot $f.RelPath)
                Label = (Join-Path $set.Repo $f.RelPath)
            }
        }
    }
}

# Ordinal: PowerShell's -ne ignores case, so a case-only edit used to count as a match.
foreach ($p in $deployedPairs) {
    if (-not (Test-Path $p.Repo) -or -not (Test-Path $p.Local)) { continue }   # absence reported above
    $expected = Expand-Tokens -Text (Read-TextFile $p.Repo) `
                              -UserName $env:USERNAME -ConfigRoot $configRoot -Desktop $desktopTok
    if (-not [string]::Equals((Read-TextFile $p.Local), $expected, [StringComparison]::Ordinal)) { $drifted += $p.Label }
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

# The block's BODY is compared, not just its start marker: a block missing a line, or
# with its dot-source commented out, starts the same way and wires nothing. Line
# endings are normalized because deploy writes CRLF around the block and an editor
# may not. Returns 'current', 'differs', 'unterminated' (start marker, no end) or 'missing'.
function Get-ProfileBlockState {
    param([string]$Path)
    if (-not (Test-ClaudeProfileBlock -Path $Path)) { return 'missing' }
    $m = Get-ClaudeBlockMarkers
    $found = [regex]::Match((Read-TextFile $Path), "(?s)" + $m.DetectPattern + ".*?" + [regex]::Escape($m.End))
    if (-not $found.Success) { return 'unterminated' }
    $expected = (Get-ClaudeProfileBlock).Replace("`r`n", "`n").Trim()
    if ([string]::Equals($found.Value.Replace("`r`n", "`n").Trim(), $expected, [StringComparison]::Ordinal)) { return 'current' }
    return 'differs'
}

# Launcher code OUTSIDE the managed block: hand-written claude-*/codex-* functions, or a
# token export, from before the block existed. The block redefines the launchers, so the
# profile reads as wired while the old lines still run at every shell start -- exporting
# a token into every process, and keeping removed launchers callable. Returns the line
# numbers (comment lines are skipped for the mention test); the block itself is skipped
# only when both of its markers are present.
function Get-ProfileLegacyLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $m = Get-ClaudeBlockMarkers
    $lines = @((Read-TextFile $Path) -split "\r?\n")
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match $m.DetectPattern) { $start = $i }
        elseif ($start -ge 0 -and $lines[$i].Contains($m.End)) { $end = $i; break }
    }
    $hits = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($end -ge 0 -and $i -ge $start -and $i -le $end) { continue }
        $line = $lines[$i]
        if ($line -match '(?i)^\s*function\s+(global:|script:)?(claude-[\w-]*|codex-[\w-]*|Get-AnthropicApiKey)\b' -or
            ($line -notmatch '^\s*#' -and $line -match '(?i)GITHUB_PERSONAL_ACCESS_TOKEN|Get-Secret\.ps1')) { $hits += ($i + 1) }
    }
    return $hits
}

$profilePaths = @(Get-ProfilePaths)
$wired = @()
$unwired = @()
$wiredEditions = @()
foreach ($p in $profilePaths) {
    $edition = switch -Wildcard ($p) {
        '*\WindowsPowerShell\*' { 'Windows PowerShell 5.1' }
        '*\PowerShell\*'        { 'PowerShell 7+' }
        default                 { 'PowerShell' }
    }
    $state = Get-ProfileBlockState -Path $p
    if ($state -eq 'current') { $wired += $p; $wiredEditions += $edition } else { $unwired += $p }
    switch ($state) {
        'current'      { Check OK "$edition profile sources claude-functions.ps1" }
        'differs'      { Check FAIL "$edition profile's managed block differs from the one deploy writes (edited, stale, or missing a line) -- $p" "run deploy.ps1, which replaces the block in place" }
        'unterminated' { Check FAIL "$edition profile has the managed block's start marker but not its end marker -- $p" "delete the damaged block by hand, then run deploy.ps1" }
        'missing'      { Check FAIL "$edition profile is missing the managed block -- $p" "run deploy.ps1" }
    }
    $legacy = @(Get-ProfileLegacyLines -Path $p)
    if ($legacy.Count) {
        Check WARN "$edition profile defines launchers or reads secrets OUTSIDE the managed block -- $p, line(s) $($legacy -join ', ')" "these predate the managed block and still run at every shell start; delete them by hand -- deploy never edits outside its block"
    }
}

if ($profilePaths.Count -eq 0) {
    Check FAIL "could not determine any PowerShell profile path"
} elseif ($unwired.Count -eq 0) {
    Check OK "every discovered profile is wired -- the functions exist in whichever shell you open"
}

# A wired profile still does nothing if the edition's execution policy refuses to run
# it -- and Windows PowerShell 5.1's default on a Windows client is Restricted. Each
# edition is asked in that edition, because the two keep separate policies. The
# Process scope is ignored: this script runs under -ExecutionPolicy Bypass, and
# PSExecutionPolicyPreference is often inherited from the launching shell, so the
# child's own effective policy reflects how doctor was started, not how a terminal
# the user opens will behave. A PSExecutionPolicyPreference set persistently (User or
# Machine environment) is different -- every new shell inherits it -- so it stands in
# for the Process scope.
#
# Get-ExecutionPolicy -List from that edition, as Scope -> policy name; @{} if unreadable.
function Get-EditionPolicyScopes {
    param([string]$Exe)
    $query = 'Get-ExecutionPolicy -List | ForEach-Object { "{0}={1}" -f $_.Scope, $_.ExecutionPolicy }'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($query))
    $scopes = @{}
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($line in @(& $Exe -NoProfile -NonInteractive -EncodedCommand $encoded 2>$null)) {
            if ("$line" -match '^(\w+)=(\w+)$') { $scopes[$Matches[1]] = $Matches[2] }
        }
    } catch { }
    finally { $ErrorActionPreference = $previousEap }
    return $scopes
}

# The policy a freshly opened shell of that edition runs under, and the scope that set it.
function Resolve-ProfilePolicy {
    param([hashtable]$Scopes, [string]$Default, [string]$PersistentProcess)
    $s = @{} + $Scopes
    $s.Remove('Process')
    if ($PersistentProcess) { $s['Process'] = $PersistentProcess }
    foreach ($scope in @('MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser', 'LocalMachine')) {
        if ($s[$scope] -and $s[$scope] -ne 'Undefined') { return @{ Policy = $s[$scope]; From = $scope } }
    }
    return @{ Policy = $Default; From = 'default, every scope Undefined' }
}

$persistentProcessPolicy = @('User', 'Machine' | ForEach-Object {
    [Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference', $_) } | Where-Object { $_ })[0]
$editionShells = @{
    'Windows PowerShell 5.1' = @{ Exe = 'powershell.exe'; Default = 'Restricted' }
    'PowerShell 7+'          = @{ Exe = 'pwsh';           Default = 'RemoteSigned' }
}
foreach ($edition in @($wiredEditions | Select-Object -Unique | Where-Object { $editionShells.ContainsKey($_) })) {
    $shell = $editionShells[$edition]
    $exe = Get-Command $shell.Exe -ErrorAction SilentlyContinue
    if (-not $exe) { continue }    # profile wired for an edition not installed here
    $scopes = Get-EditionPolicyScopes -Exe $exe.Source
    if ($scopes.Count -eq 0) {
        Check WARN "could not read the $edition execution policy" "run Get-ExecutionPolicy -List in $edition"
        continue
    }
    $r = Resolve-ProfilePolicy -Scopes $scopes -Default $shell.Default -PersistentProcess $persistentProcessPolicy
    if ($r.Policy -in @('Restricted', 'AllSigned')) {
        $fix = switch ($r.From) {
            { $_ -in @('MachinePolicy', 'UserPolicy') } { "set by Group Policy ($($r.From)), which Set-ExecutionPolicy cannot override -- ask whoever manages this machine"; break }
            'Process' { "the persistent PSExecutionPolicyPreference environment variable sets it -- remove it, or set it to RemoteSigned"; break }
            default   { "in $edition`: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" }
        }
        Check FAIL "$edition execution policy is $($r.Policy) ($($r.From)) -- its profile never runs, so the claude-*/codex-* functions do not exist there" $fix
    } else {
        Check OK "$edition execution policy is $($r.Policy) ($($r.From)) -- the profile runs"
    }
}

# Which shell Terminal opens matters only if it is one of the wired editions: a default
# of Command Prompt, WSL or a VS developer shell never loads these profiles at all.
# Judged by what the profile launches -- commandline, or the dynamic-profile source
# Terminal generates for PowerShell 7 -- not by its display name, which is the user's.
function Get-TerminalProfileEdition {
    param([string]$SettingsPath, [string]$Guid)
    try {
        $raw = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
        $termProfile = @(($raw | ConvertFrom-Json).profiles.list |
            Where-Object { $_.guid -eq $Guid -or $_.name -eq $Guid })[0]
    } catch { return $null }
    if (-not $termProfile) { return $null }
    $cmd = [string]$termProfile.commandline
    if ($termProfile.source -eq 'Windows.Terminal.PowershellCore' -or
        $cmd -match '(?i)(^|[\\/"\s])pwsh(\.exe)?("|\s|$)') { return 'PowerShell 7+' }
    if ($cmd -match '(?i)(^|[\\/"\s])powershell(\.exe)?("|\s|$)') { return 'Windows PowerShell 5.1' }
    return $null
}

$term = Get-TerminalDefaultProfile
if ($term) {
    $termEdition = Get-TerminalProfileEdition -SettingsPath $term.Path -Guid $term.DefaultProfileGuid
    $note = "Windows Terminal opens '$($term.DefaultProfileName)' by default"
    if (-not $termEdition) {
        Check WARN "$note, which is not Windows PowerShell or PowerShell 7 -- the claude-*/codex-* functions are not defined there" "Terminal > Settings > Startup > Default profile: pick Windows PowerShell or PowerShell"
    } elseif ($termEdition -in $wiredEditions) {
        Check OK "$note ($termEdition, wired above)"
    } else {
        Check WARN "$note ($termEdition), whose profile is not wired" "run deploy.ps1"
    }
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

# Whether a stored secret decrypts, asked of Get-Secret.ps1 itself: $null when it does,
# else Get-Secret's own one-line reason, which becomes the FAIL text. The value is never
# returned. That line is written with [Console]::Error, which no PowerShell redirection
# catches in-process -- 2>$null let it through onto the report -- so the console's error
# writer is swapped out for the length of the call.
function Get-SecretFailure {
    param([string]$Name)
    $value = $null
    $captured = [System.IO.StringWriter]::new()
    $consoleError = [Console]::Error
    [Console]::SetError($captured)
    try { $value = & (Join-Path $repoRoot 'Get-Secret.ps1') -Name $Name 2>$null }
    catch { $captured.WriteLine($_.Exception.Message) }
    finally { [Console]::SetError($consoleError) }
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $null }
    $reason = @($captured.ToString() -split "\r?\n" | Where-Object { $_.Trim() })[0]
    if ($reason) { return $reason.Trim() }
    return 'Get-Secret.ps1 printed nothing'
}

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
    #
    # A secret registered for a plugin (its 'plugin' field) is needed only while that
    # plugin is enabled in settings.json. Only an explicit $false skips one: if the
    # applicability test fails or answers anything else, the secret is checked anyway,
    # because reporting one too many beats hiding one.
    $settingsForSecrets = Join-Path $claudeHome 'settings.json'
    foreach ($sec in $registry) {
        $applies = $null
        try { $applies = Test-SecretApplies -Secret $sec -SettingsPath $settingsForSecrets } catch { }
        if ($applies -is [bool] -and -not $applies) {
            Write-Host "  [ -- ] $($sec.name) not needed -- plugin $($sec.plugin) is not enabled" -ForegroundColor DarkGray
            continue
        }
        $encPath = Join-Path $claudeHome ".$($sec.name).enc"
        if (-not (Test-Path $encPath)) {
            Check WARN "$($sec.name) absent -- $($sec.purpose)" "& `"$repoRoot\Set-Secret.ps1`" -Name $($sec.name)"
            continue
        }
        $failure = Get-SecretFailure -Name $sec.name
        if ($failure) {
            Check FAIL "$($sec.name) present but cannot be decrypted -- $failure" "re-encrypt it on this machine: & `"$repoRoot\Set-Secret.ps1`" -Name $($sec.name)"
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

$skillSets = @($plan.Dirs | Where-Object { $_.Repo -like '*skills' })

if ($skillSets.Count -eq 0) {
    Check WARN "no skill sets in the artifact manifest"
} else {
    $skillDirs = @()
    foreach ($set in $skillSets) {
        $skillRoot = Join-Path $repoRoot $set.Repo
        if (Test-Path $skillRoot) { $skillDirs += @(Get-ChildItem $skillRoot -Directory) }
    }

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

# research-worker.md is generated from "System Prompt.txt" (see the directed-agent manifest
# entries in lib\Common.ps1), so the subset comparison that used to live here is covered
# by the generated-artifact staleness check above: the worker cannot drift from the
# prompt any more, only its head fragment can change.

# --- Codex target ------------------------------------------------------------
# The Codex half of the manifest. Scope note: the personal profile is CLI-flag-only
# (verified on 0.149.0 -- a `profile` key in config.toml is rejected as legacy), so
# everything here certifies the codex-sp path, not Codex-at-large.
Section "Codex target"

$codexVerLine = Get-ExeVersion 'codex'
if (-not $codexVerLine) {
    Check WARN "codex not found on PATH -- Codex target not checked" "npm install -g @openai/codex"
} else {
    # Version floor. compat.json records the oldest Codex these checks hold on: the
    # surfaces this repo leans on (file profiles, model_instructions_file, agent TOML)
    # are version-sensitive, and the schema has already been caught documenting a key
    # the binary rejects. There is deliberately no ceiling -- Codex ships every few
    # days, so a "newest certified" pin was stale within the week and its warning was
    # permanently on. The per-version verification is the probes below, run every time.
    $codexVer = $null
    if ($codexVerLine -match '(\d+)\.(\d+)\.(\d+)') { $codexVer = [version]$Matches[0] }
    $compatPath = Join-Path $repoRoot 'compat.json'
    if (-not $codexVer) {
        Check WARN "cannot parse codex version from '$codexVerLine'"
    } elseif (-not (Test-Path $compatPath)) {
        Check WARN "compat.json missing -- no version floor" "restore compat.json in the repo"
    } else {
        try {
            $min = [version](Get-Content $compatPath -Raw -Encoding UTF8 | ConvertFrom-Json).codex.min
            if ($codexVer -lt $min) {
                Check FAIL "codex $codexVer is below the minimum supported $min" "codex update"
            } else {
                Check OK "codex $codexVer (min $min)"
            }
        } catch {
            Check FAIL "compat.json is not valid JSON -- $($_.Exception.Message)"
        }
    }

    # The launcher and its repo pointer.
    $codexFn = Join-Path $codexHome 'codex-functions.ps1'
    if (Test-Path $codexFn) { Check OK "codex-functions.ps1 deployed to ~/.codex/" }
    else { Check FAIL "missing $codexFn" "run deploy.ps1" }

    foreach ($targetHome in @($claudeHome, $codexHome)) {
        $ptr = Join-Path $targetHome '.config-root'
        if (-not (Test-Path $ptr)) {
            Check WARN "missing repo pointer $ptr (functions fall back to <Desktop>\claude-config)" "run deploy.ps1"
        } elseif (((Get-Content $ptr -Raw).Trim()) -ne $repoRoot) {
            Check WARN "repo pointer $ptr points at '$((Get-Content $ptr -Raw).Trim())', not this repo" "run deploy.ps1 from the repo the functions should use"
        } else {
            Check OK "repo pointer $ptr -> this repo"
        }
    }

    # Profile probe: `codex -p personal debug prompt-input` is the one local, sanctioned
    # command that loads a profile without a model call. It catches a missing codex
    # install and a syntactically broken profile TOML (verified: malformed TOML exits 1).
    # KNOWN LIMIT on 0.149.0: prompt-input renders the input list, not the base
    # instructions, so it can NOT verify that model_instructions_file replacement took
    # effect -- a broken replacement shows up in the first codex-sp session instead.
    if (Test-Path (Join-Path $codexHome 'personal.config.toml')) {
        $probeOut = $null
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $probeOut = & codex -p personal debug prompt-input 2>&1 | Out-String } catch { }
        finally { $ErrorActionPreference = $previousEap }
        if ($LASTEXITCODE -eq 0) {
            Check OK "personal profile loads (codex -p personal debug prompt-input)"
            # Coexistence: the deployed global AGENTS.md must still reach the model's
            # input while the profile is active. Its 'GENERATED from' header line is
            # stable across content edits, so look for that exact line -- not any
            # 'GENERATED from', which <Desktop>\AGENTS.md also carries and which
            # prompt-input includes whenever doctor runs from the Desktop. The probe
            # prints JSON-escaped text, hence the doubled-backslash form. This is the
            # per-upgrade re-verification: the config reference calls
            # model_instructions_file a replacement "instead of AGENTS.md", and the
            # coexistence observed today is a behavior of this version, not a contract.
            $globalAgents = Join-Path $codexHome 'AGENTS.md'
            if (Test-Path $globalAgents) {
                $agentsHeader = @([System.IO.File]::ReadAllLines($globalAgents) | Where-Object { $_.Trim() })[0]
                $probeText = "$probeOut"
                if ($agentsHeader -and ($probeText.Contains($agentsHeader.Trim()) -or $probeText.Contains($agentsHeader.Trim().Replace('\', '\\')))) {
                    Check OK "deployed AGENTS.md reaches the prompt input under the personal profile"
                } else {
                    Check FAIL "deployed ~/.codex/AGENTS.md does NOT appear in the prompt input" "a Codex update may have changed AGENTS.md discovery; rework the codex-sp launcher, or pin codex to the last version that passed"
                }
            }
        } else {
            $firstLine = @($probeOut -split "`r?`n" | Where-Object { $_ })[0]
            Check FAIL "personal profile probe failed -- $firstLine" "fix ~/.codex/personal.config.toml, or re-run deploy.ps1"
        }
    } else {
        Check FAIL "missing ~/.codex/personal.config.toml" "run deploy.ps1"
    }

    # Codex agent TOMLs: the three required keys, checked textually. A parse-level
    # check lives in the probe above only for the profile; agents are read lazily by
    # Codex, so a missing key would otherwise surface mid-session.
    foreach ($t in @(Get-ChildItem (Join-Path $repoRoot 'codex\agents') -Filter '*.toml' -File -ErrorAction SilentlyContinue)) {
        $tomlText = Get-Content $t.FullName -Raw -Encoding UTF8
        $missingKeys = @()
        foreach ($k in @('name', 'description', 'developer_instructions')) {
            if ($tomlText -notmatch "(?m)^\s*$k\s*=") { $missingKeys += $k }
        }
        if ($missingKeys.Count -eq 0) { Check OK "codex agent $($t.Name) declares name/description/developer_instructions" }
        else { Check FAIL "codex agent $($t.Name) is missing: $($missingKeys -join ', ')" "Codex agent TOML requires all three fields" }
    }
}

# Generated artifacts: repo-side checks, meaningful even without codex installed.
$staleGen = @()
try {
    $staleGen = @(Update-GeneratedArtifacts -RepoRoot $repoRoot -Manifest $plan -Check | Where-Object { $_.State -eq 'stale' })
    if ($staleGen.Count -eq 0) {
        Check OK "generated files (Codex AGENTS.md, directed agent) match their sources"
    } else {
        Check FAIL "stale generated file(s): $(@($staleGen | ForEach-Object Label) -join ', ')" "run collect.ps1 (rebuilds them), then deploy.ps1"
    }
} catch {
    Check FAIL "generated-artifact build failed -- $($_.Exception.Message)"
}

# Lint the generated Codex files for Claude-only vocabulary that leaked past the
# markers. A wrong instruction in AGENTS.md actively misleads Codex, which is worse
# than a missing one -- but unmarked shared prose can legitimately mention Claude by
# name, so this warns and names lines rather than failing.
# 'claude-sp(sp)?\b', not 'claude-sp': the bare form is a substring of the innocent
# word 'Claude-specific'. Same for claude-or vs 'claude-orchestrated' etc.
$lintPattern = '(?i)claude-in-chrome|claude-or(-sp)?(sp)?\b|claude-sp(sp)?\b|ANTHROPIC_|OpenRouter|Tool Search|file-manager agent'
# Slash commands of Claude-only skills (skill sets that deploy only under ~/.claude),
# taken from the manifest so a new Claude-only skill is linted without editing this.
# The lookbehind skips path segments such as 'global/skills/<name>/'.
$claudeOnlySkills = @()
foreach ($set in @($plan.Dirs | Where-Object { $_.Repo -like '*skills' })) {
    $outsideClaude = @($set.Destinations | Where-Object { -not $_.StartsWith($claudeHome, [StringComparison]::OrdinalIgnoreCase) })
    if ($outsideClaude.Count -eq 0) { $claudeOnlySkills += @(Get-ArtifactMembers -RepoRoot $repoRoot -Artifact $set) }
}
$slashPattern = if ($claudeOnlySkills.Count) {
    '(?i)(?<![\w/\\.~}-])/(' + (($claudeOnlySkills | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![\w-])'
} else { $null }
# Codex outputs only: the directed agent is Claude's own, and may name Claude tooling freely.
foreach ($g in @($plan.Files | Where-Object { $_.GeneratedFrom -and $_.Builder -ne 'agent' })) {
    $gp = Join-Path $repoRoot $g.Repo
    if (-not (Test-Path $gp)) { continue }
    $hits = @()
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($gp)) {
        $n++
        if ($line -match $lintPattern -or ($slashPattern -and $line -match $slashPattern)) { $hits += $n }
    }
    if ($hits.Count -eq 0) { Check OK "$($g.Repo) carries no Claude-only vocabulary" }
    else { Check WARN "$($g.Repo) mentions Claude-only tooling on line(s) $($hits -join ', ')" "wrap the source section in claude-only markers if it should not reach Codex" }
}

# Machine state must never be tracked. The manifest deliberately excludes ~/.codex
# runtime files; this catches one being added by hand.
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$trackedCodex = @()
try { $trackedCodex = @(& git -C $repoRoot ls-files 'codex/' 2>$null | Where-Object { $_ }) } catch { }
finally { $ErrorActionPreference = $previousEap }
$badTracked = @($trackedCodex | Where-Object {
    $_ -match '(?i)(^|/)(auth\.json|config\.toml|history\.jsonl|cap_sid|installation_id)$' -or $_ -match '(?i)\.(sqlite|sqlite-shm|sqlite-wal)$' -or $_ -match '(?i)(^|/)(cache|log|memories|sessions)/'
})
if ($badTracked.Count -gt 0) {
    Check FAIL "codex machine state is tracked in the repo: $($badTracked -join ', ')" "git rm --cached it; machine state never syncs"
} else {
    Check OK "no codex machine state tracked in the repo"
}

# --- Public mirror -----------------------------------------------------------
# publish.ps1 is private-only (its manifest names the systems that must never be
# published), so this section exists in the private repo alone and a public fork skips
# it. Shelling out keeps every private name out of this shared file; a child process
# gives a clean exit code, and the summary line carries the count. The public repo used
# to fall behind by whole refactors because nothing looked unless someone remembered to.
$publishScript = Join-Path $repoRoot 'publish.ps1'
if (Test-Path $publishScript) {
    Section "Public mirror"
    $pubOut = ''
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $pubOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publishScript 2>&1 | Out-String } catch { }
    finally { $ErrorActionPreference = $previousEap }
    $publishCmd = "powershell -ExecutionPolicy Bypass -File `"$publishScript`""
    # publish.ps1 fetches origin first and says so when it cannot; an offline "in sync"
    # is only as fresh as the last fetch.
    $staleNote = if ($pubOut -match 'could not fetch origin') { " (as of the last fetch -- origin unreachable)" } else { "" }
    if ($LASTEXITCODE -eq 0) {
        Check OK "public repo is in sync with this one$staleNote"
    } elseif ($pubOut -match 'No git repository at (.+)') {
        Check OK "public clone not present on this machine ($($Matches[1].Trim())) -- publish check skipped"
    } elseif ($pubOut -cmatch '\[X\] (sensitive term at|sensitive term in commit|forbidden email in commit|PRIVATE-ONLY FILE)') {   # -cmatch: the sweep's section title is 'Sensitive terms'
        Check FAIL "the public tree or its unpushed commits contain private content" "run $publishCmd and fix every [X] before anything is pushed"
    } elseif ($pubOut -match 'public clone is (\d+) commit\(s\) behind origin') {
        Check WARN "the public clone is $($Matches[1]) commit(s) behind origin, so the comparison is against an old tree" "git pull --ff-only in the public clone (run $publishCmd for its path), then re-run doctor"
    } elseif ($pubOut -match '=== (\d+) problem\(s\)') {
        Check WARN "public repo has fallen behind: $($Matches[1]) problem(s)" "run $publishCmd for the list, then -Apply, review and commit in the public clone"
    } else {
        Check WARN "publish check did not complete" "run $publishCmd"
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
