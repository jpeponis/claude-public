# bootstrap.ps1 -- Install this Claude Code configuration on a fresh Windows machine.
#
# Forks the repo to your GitHub account, clones the fork, deploys the config, verifies it.
# The fork is the default rather than an afterthought: sync-config pushes to 'origin', so a
# plain clone of someone else's repo is a setup whose push half is broken from day one.
#
# Straight from the web, nothing to download first:
#   irm https://raw.githubusercontent.com/jpeponis/claude-public/main/bootstrap.ps1 | iex
#
# With options, or from a clone you already have:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jpeponis/claude-public/main/bootstrap.ps1))) -DryRun
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -DryRun
#
#   -DryRun       Print every command and change, run none of them.
#   -NoFork       Read-only clone instead of a fork. Everything works except config push.
#   -Dest <path>  Install somewhere other than <Desktop>\claude-config.
#   -Yes          Skip the confirmation prompt.
#
# Deliberately self-contained: it runs before the repo it installs exists, so unlike the
# other scripts here it cannot dot-source lib\Common.ps1.
#
# Exit code: 0 on success or a declined prompt; 1 on failed preflight, refusal, or a
# doctor.ps1 that reports failures afterwards.

[CmdletBinding()]
param(
    [string]$Dest,
    [switch]$NoFork,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# PowerShell 7.4+ can turn a non-zero exit code from a native command into a terminating
# error, which would bypass every exit-code check below including the clone retry. Opt out:
# git and gh results are inspected by hand here.
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$UpstreamOwner = 'jpeponis'
$UpstreamName  = 'claude-public'
$UpstreamSlug  = "$UpstreamOwner/$UpstreamName"
$UpstreamUrl   = "https://github.com/$UpstreamSlug.git"

# --- Helpers -----------------------------------------------------------------
function Say {
    param([string]$Text, [string]$Color = 'Gray', [switch]$Plan)
    $prefix = ''
    if ($DryRun -and $Plan) { $prefix = '[DRY] ' }
    Write-Host "$prefix$Text" -ForegroundColor $Color
}

function Section { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor Cyan }

function Fail {
    param([string[]]$Lines)
    Write-Host ''
    foreach ($l in $Lines) { Write-Host $l -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Nothing further was installed. Fix the above and run bootstrap again.' -ForegroundColor DarkGray
    exit 1
}

function Have { param([string]$Exe) return [bool](Get-Command $Exe -ErrorAction SilentlyContinue) }

# Prints each command before running it, so the transcript shows exactly what was done to
# the machine. Returns the exit code (0 under -DryRun). stderr stays attached to the
# console on purpose: git reports clone progress there.
function Run {
    param([string]$Exe, [string[]]$Arguments)
    Say "  > $Exe $($Arguments -join ' ')" 'DarkGray' -Plan
    if ($DryRun) { return 0 }
    & $Exe @Arguments
    return $LASTEXITCODE
}

# Runs a native command with its output discarded and returns the exit code plus stdout.
#
# Redirecting a native command's stderr turns each stderr line into a PowerShell error
# record, and with $ErrorActionPreference = 'Stop' that record is TERMINATING. So
# 'git remote get-url' in a directory that is not a repo, or 'gh auth status' when
# signed out -- both entirely expected here, both answered by an exit code -- would
# abort the script with a raw NativeCommandError instead of reaching the message
# written for that case. Relax the preference around exactly these calls.
function Invoke-Quiet {
    param([string]$Exe, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>$null
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = "$out".Trim() }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-Remote {
    param([string]$Dir, [string]$Name)
    if (-not (Test-Path (Join-Path $Dir '.git'))) { return '' }
    $r = Invoke-Quiet 'git' @('-C', $Dir, 'remote', 'get-url', $Name)
    if ($r.Code -ne 0) { return '' }
    return $r.Out
}

# Owner and repo name from a git remote URL. Compares whole names, so a checkout of some
# other repo called 'claude' is not mistaken for one of 'claude-public' -- which is exactly
# what a substring match would do, to a directory it then wrote into.
function Split-RemoteUrl {
    param([string]$Url)
    if ($Url -match '[/:]([^/:]+)/([^/]+?)(\.git)?$') {
        return @{ Owner = $Matches[1]; Name = $Matches[2] }
    }
    return @{ Owner = ''; Name = '' }
}

Write-Host ''
Write-Host '=== Claude Code portable config: bootstrap ===' -ForegroundColor White
Write-Host "upstream: $UpstreamSlug" -ForegroundColor DarkGray

# --- Where does this run from, and where does the repo go? -------------------
# Running from inside an existing clone is normal (the README used to say "git clone
# first"), so detect it and skip cloning. An explicit -Dest always wins -- that is how
# you install a second copy somewhere else.
$localRepo = $null
if (-not $Dest -and $PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'deploy.ps1'))) {
    $localRepo = $PSScriptRoot
}
if (-not $Dest) {
    if ($localRepo) {
        $Dest = $localRepo
    } else {
        # GetFolderPath, not "$env:USERPROFILE\Desktop": OneDrive Known Folder Move
        # redirects Desktop on a default Windows 11 consumer setup.
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
        $Dest = Join-Path $desktop 'claude-config'
    }
}

# --- Preflight: everything checked before anything is written ----------------
Section 'Preflight'

if (-not (Have 'git')) {
    Fail @(
        'git is required and was not found on PATH.',
        '  winget install --id Git.Git -e',
        'Then open a new terminal and run bootstrap again.'
    )
}
Say '  [ OK ] git' 'Green'

if (-not $NoFork) {
    if (-not (Have 'gh')) {
        Fail @(
            'The GitHub CLI (gh) is required to fork this repo to your account.',
            '  winget install --id GitHub.cli -e',
            '  gh auth login',
            'Then open a new terminal and run bootstrap again.',
            '',
            'Or skip forking (read-only clone, no config push):  bootstrap.ps1 -NoFork'
        )
    }
    if ((Invoke-Quiet 'gh' @('auth', 'status')).Code -ne 0) {
        Fail @(
            'gh is installed but not authenticated.',
            '  gh auth login',
            'Then run bootstrap again. Or use -NoFork for a read-only clone.'
        )
    }
    Say '  [ OK ] gh, authenticated' 'Green'
}

# Claude Code and Node are what this config is FOR, but installing config before the app
# is a legitimate order to do things in, so these warn rather than stop.
if (Have 'claude') { Say '  [ OK ] claude on PATH' 'Green' }
else { Say '  [WARN] claude not on PATH -- npm install -g @anthropic-ai/claude-code' 'Yellow' }

if (-not (Have 'node')) {
    Say '  [WARN] node not on PATH -- Claude Code needs Node.js 22 or newer' 'Yellow'
} else {
    $nodeVer = "$(& node --version)".Trim()
    $major = 0
    if ($nodeVer -match 'v(\d+)\.') { $major = [int]$Matches[1] }
    if ($major -ge 22) { Say "  [ OK ] node $nodeVer" 'Green' }
    else { Say "  [WARN] node $nodeVer is older than the v22 Claude Code needs" 'Yellow' }
}

# --- Who are we, and is a fork needed at all? --------------------------------
$me = ''
if (-not $NoFork) {
    $me = "$(& gh api user --jq .login)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $me) {
        Fail @('Could not read your GitHub login from gh.', '  gh auth status')
    }
}

# You cannot fork a repo you already own, and do not need to -- push access is already
# there. This is also what lets the upstream owner run bootstrap at all.
$ownsUpstream = ($me -eq $UpstreamOwner)
$willFork     = (-not $NoFork) -and (-not $ownsUpstream)
$forkSlug     = "$me/$UpstreamName"

# --- Assess the destination --------------------------------------------------
# Never write into a directory holding something else. On the author's own machine
# <Desktop>\claude-config is a different, private repo, so this refusal is the
# difference between a bootstrap and an accident.
$reuseExisting = [bool]$localRepo

if (-not $reuseExisting -and (Test-Path $Dest)) {
    $notEmpty = [bool](Get-ChildItem -Force $Dest -ErrorAction SilentlyContinue | Select-Object -First 1)
    $existing = Split-RemoteUrl (Get-Remote $Dest 'origin')

    if (-not $notEmpty) {
        $reuseExisting = $false          # empty directory: clone straight into it
    } elseif ($existing.Name -eq $UpstreamName) {
        $reuseExisting = $true
        Say ''
        Say "$Dest already holds a clone of $UpstreamName; reusing it rather than re-cloning." 'Yellow'
    } else {
        $what = 'is not empty'
        if ($existing.Name) { $what = "is a different git repository (origin = $($existing.Name))" }
        Fail @(
            "$Dest already exists and $what.",
            'Bootstrap will not write over it. Pick another location:',
            "  bootstrap.ps1 -Dest `"$Dest-new`""
        )
    }
}

# In an existing clone the remote decides whether sync works at all. Pointing at someone
# else's repo means push fails, which is the whole reason forking is the default here.
$rewireRemotes = $false
if ($reuseExisting -and $willFork) {
    $originOwner = (Split-RemoteUrl (Get-Remote $Dest 'origin')).Owner
    if ($originOwner -eq $me)               { $willFork = $false }
    elseif ($originOwner -eq $UpstreamOwner) { $rewireRemotes = $true }
}

# --- Plan, then confirm ------------------------------------------------------
Section 'Plan'

$plan = @()
if ($willFork)          { $plan += "Fork $UpstreamSlug to $forkSlug" }
elseif ($ownsUpstream)  { $plan += "Skip the fork -- you own $UpstreamSlug and can already push to it" }
elseif ($NoFork)        { $plan += 'Skip the fork (-NoFork) -- read-only clone, sync-config push will not work' }
else                    { $plan += "Use the fork you already have at $forkSlug" }

if ($rewireRemotes)     { $plan += "Repoint origin at $forkSlug, keeping $UpstreamSlug as upstream" }
elseif ($reuseExisting) { $plan += "Use the clone already at $Dest" }
else                    { $plan += "Clone into $Dest" }

$plan += 'Deploy the config (deploy.ps1). It backs up whatever it replaces, and adds a'
$plan += '   managed block to your PowerShell profiles instead of replacing them'
$plan += 'Verify the result (doctor.ps1)'

$i = 0
foreach ($line in $plan) {
    if ($line.StartsWith('   ')) { Write-Host "  $line" -ForegroundColor White; continue }
    $i++
    Write-Host ("  {0}. {1}" -f $i, $line) -ForegroundColor White
}

Write-Host ''
Write-Host "  destination: $Dest" -ForegroundColor DarkGray
if ($me) { Write-Host "  github user: $me" -ForegroundColor DarkGray }

if (-not $Yes -and -not $DryRun) {
    Write-Host ''
    $reply = Read-Host 'Proceed? [Y/n]'
    if ($reply -and $reply -notmatch '^(y|yes)$') {
        Write-Host 'Cancelled -- nothing was changed.' -ForegroundColor Yellow
        exit 0
    }
}

# --- Fork --------------------------------------------------------------------
if ($willFork) {
    Section 'Fork'
    # The REST endpoint rather than 'gh repo fork': no interactive prompting, no implicit
    # remote or clone side effects, and it returns the fork's full name. Forking is
    # idempotent -- if you already have one, GitHub returns it unchanged.
    Say "  > gh api --method POST repos/$UpstreamSlug/forks --jq .full_name" 'DarkGray' -Plan
    if (-not $DryRun) {
        $created = "$(& gh api --method POST "repos/$UpstreamSlug/forks" --jq .full_name)".Trim()
        if ($LASTEXITCODE -ne 0 -or -not $created) {
            Fail @(
                "Could not fork $UpstreamSlug.",
                'Check that your gh token carries repo scope:',
                '  gh auth status',
                '  gh auth refresh -h github.com -s repo',
                'Or install without forking:  bootstrap.ps1 -NoFork'
            )
        }
        $forkSlug = $created
        Say "  forked to $forkSlug" 'Green'
    }
}

# --- Clone, or rewire an existing clone --------------------------------------
if ($rewireRemotes) {
    Section 'Remotes'
    if ((Run 'git' @('-C', $Dest, 'remote', 'set-url', 'origin', "https://github.com/$forkSlug.git")) -ne 0) {
        Fail 'Could not repoint origin at your fork.'
    }
    if (-not (Get-Remote $Dest 'upstream')) {
        if ((Run 'git' @('-C', $Dest, 'remote', 'add', 'upstream', $UpstreamUrl)) -ne 0) {
            Fail 'Could not add the upstream remote.'
        }
    }
} elseif (-not $reuseExisting) {
    Section 'Clone'
    $source = $UpstreamSlug
    if (-not $NoFork -and -not $ownsUpstream) { $source = $forkSlug }

    # A brand new fork can take a few seconds to become clonable, so retry briefly rather
    # than failing on a race the user can do nothing about.
    $attempt = 0
    while ($true) {
        $attempt++
        if ((Run 'gh' @('repo', 'clone', $source, $Dest)) -eq 0) { break }
        if ($attempt -ge 5 -or -not $willFork) {
            Fail @("Could not clone $source into $Dest.", 'Check that the path is writable and github.com is reachable.')
        }
        Say "  clone failed (a new fork takes a moment to become available); retrying in 3s [$attempt/5]" 'Yellow'
        Start-Sleep -Seconds 3
    }

    if ($willFork -and -not $DryRun -and -not (Get-Remote $Dest 'upstream')) {
        if ((Run 'git' @('-C', $Dest, 'remote', 'add', 'upstream', $UpstreamUrl)) -ne 0) {
            Say '  [WARN] could not add the upstream remote; pull updates with the full URL instead' 'Yellow'
        }
    }
}

# --- Deploy ------------------------------------------------------------------
Section 'Deploy'

$deployScript = Join-Path $Dest 'deploy.ps1'
if (Test-Path $deployScript) {
    & $deployScript -DryRun:$DryRun
} elseif ($DryRun) {
    Say "  would run $deployScript" 'DarkGray' -Plan
} else {
    Fail @("The clone at $Dest has no deploy.ps1.", "It looks incomplete -- delete it and run bootstrap again.")
}

# --- Verify ------------------------------------------------------------------
$doctorScript = Join-Path $Dest 'doctor.ps1'
$doctorFailed = $false
if ($DryRun) {
    Section 'Verify'
    Say "  would run $doctorScript" 'DarkGray' -Plan
} elseif (Test-Path $doctorScript) {
    & $doctorScript
    $doctorFailed = ($LASTEXITCODE -ne 0)
}

# --- What to do next ---------------------------------------------------------
Section 'Next'

if ($DryRun) {
    Write-Host '  Dry run complete -- nothing was written. Re-run without -DryRun to install.' -ForegroundColor Yellow
    exit 0
}

Write-Host @"
  1. Open a NEW terminal tab. The claude-* functions only exist in shells started
     after the deploy.
  2. Run:  claude-sp
     Claude Code with the custom system prompt, permissions in auto mode. This is
     the main way in; read the README before trying claude-spsp.
  3. Inside Claude Code, /sync-config and /api-agent should be in the slash command
     list, and the file-manager agent should be available.
"@

Write-Host ''
Write-Host '  Keeping it yours:' -ForegroundColor Cyan
if ($willFork -or $rewireRemotes) {
    Write-Host @"
    this machine's config -> your fork:  $Dest\sync-config.ps1 push
    later changes from upstream:         git -C "$Dest" pull upstream main
"@ -ForegroundColor DarkGray
} elseif ($ownsUpstream) {
    Write-Host "    push and pull both go to ${UpstreamSlug}:  $Dest\sync-config.ps1 push" -ForegroundColor DarkGray
} else {
    Write-Host '    this clone is read-only (-NoFork), so sync-config push will fail.' -ForegroundColor DarkGray
    Write-Host '    re-run bootstrap without -NoFork when you want it to be yours.' -ForegroundColor DarkGray
}

if ($doctorFailed) {
    Write-Host ''
    Write-Host 'doctor.ps1 reported a failure above. The install is on disk but not healthy.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
exit 0
