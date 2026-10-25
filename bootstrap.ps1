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
# Exit code: 0 on success, a dry run, or a declined prompt; 1 on failed preflight,
# refusal, or a doctor.ps1 that reports failures afterwards; deploy.ps1's own code when
# the deploy fails. Run as a file, that is the process exit code. Run from the web (both
# forms above), the script never calls 'exit' -- see Stop-Bootstrap -- and leaves the
# code in $LASTEXITCODE instead.

[CmdletBinding()]
param(
    [string]$Dest,
    [switch]$NoFork,
    [switch]$DryRun,
    [switch]$Yes
)

# Run with 'irm | iex', this text executes in the caller's own scope, so the two
# preferences set here would outlive the script. Saved here, restored at the bottom.
$bootstrapSavedEap = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

# PowerShell 7.4+ can turn a non-zero exit code from a native command into a terminating
# error, which would bypass every exit-code check below including the clone retry. Opt out:
# git and gh results are inspected by hand here.
$bootstrapSavedNativePref = $null
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $bootstrapSavedNativePref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
}

$UpstreamOwner = 'jpeponis'
$UpstreamName  = 'claude-public'
$UpstreamSlug  = "$UpstreamOwner/$UpstreamName"
$UpstreamUrl   = "https://github.com/$UpstreamSlug.git"

# --- Stopping without closing the user's shell --------------------------------
# Both web forms in the header run this text inside the user's own PowerShell session,
# where 'exit' ends the session itself. On exit code 0 -- a dry run, a declined prompt,
# a success -- Windows Terminal then closes the tab, and the output the user wanted to
# read goes with it. So only the last lines of this file decide whether to 'exit'.
# Stop-Bootstrap throws a marker exception carrying the code; the one handler at the
# bottom catches it and either exits (run as a file) or leaves the code in $LASTEXITCODE
# (run as text).
#
# Not 'break', which Scoop's installer uses for the same job: outside a loop, break
# searches up the CALL STACK for one, so a Fail inside the clone retry loop would leave
# only that loop and carry straight on into the deploy.
function Stop-Bootstrap {
    param([int]$Code)
    $e = [System.Exception]::new("bootstrap.ps1 stopped (exit code $Code)")
    $e.Data['BootstrapExitCode'] = $Code
    throw $e
}

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
    Stop-Bootstrap 1
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

# deploy.ps1 and doctor.ps1 run as child processes under -ExecutionPolicy Bypass, not
# in-process with '&'. In-process they are script FILES, and Windows PowerShell's default
# policy on a Windows client (Restricted) refuses those -- "running scripts is disabled"
# -- even though 'irm | iex' ran this script fine, since that is text, not a file. It
# used to fail exactly there, after the fork and the clone had already happened.
#
# Called as a statement, never captured: a captured child has its stdout redirected,
# which strips the colours from deploy's and doctor's reports. The caller reads
# $LASTEXITCODE straight afterwards.
function Invoke-RepoScript {
    param([string]$Path)
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path)
    if ($DryRun) { $arguments += '-DryRun' }
    Write-Host "  > powershell.exe $($arguments -join ' ')" -ForegroundColor DarkGray
    & powershell.exe @arguments
}

# A command run in Windows PowerShell 5.1, whichever edition runs this script.
# -EncodedCommand, so nothing in the command is reinterpreted by quoting on the way.
function Invoke-WindowsPowerShell {
    param([string]$Command)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    return Invoke-Quiet 'powershell.exe' @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
}

# --- Windows PowerShell's execution policy -----------------------------------
# deploy.ps1 wires the claude-*/codex-* launchers into BOTH PowerShell profiles, and a
# profile is a script: under Restricted (Windows PowerShell 5.1's default on a Windows
# client) or AllSigned it never runs, so the launchers silently do not exist there.
# PowerShell 7 keeps a separate policy that defaults to RemoteSigned and needs nothing,
# so it is 5.1 that has to be asked -- from 5.1, whichever edition runs this.
#
# The Process scope is ignored. PSExecutionPolicyPreference is usually inherited from
# whatever launched this script ('powershell -ExecutionPolicy Bypass' sets it), so it
# describes this process tree, not the terminal the user opens tomorrow.
#
# Scope -> policy name, as 5.1 reports it; @{} when it cannot be asked.
function Get-WindowsPowerShellPolicyList {
    $scopes = @{}
    if (-not (Have 'powershell.exe')) { return $scopes }
    $r = Invoke-WindowsPowerShell 'Get-ExecutionPolicy -List | ForEach-Object { "{0}={1}" -f $_.Scope, $_.ExecutionPolicy }'
    if ($r.Code -ne 0) { return $scopes }
    foreach ($m in [regex]::Matches($r.Out, '(\w+)=(\w+)')) { $scopes[$m.Groups[1].Value] = $m.Groups[2].Value }
    return $scopes
}

# The policy a freshly opened Windows PowerShell runs profiles under, and the scope that
# set it: the first scope not Undefined, by precedence, Process excluded. Every scope
# Undefined means the client default, Restricted.
function Resolve-ProfilePolicy {
    param([hashtable]$Scopes)
    foreach ($scope in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
        $p = $Scopes[$scope]
        if ($p -and $p -ne 'Undefined') { return @{ Policy = $p; From = $scope } }
    }
    return @{ Policy = 'Restricted'; From = 'the default; every scope is Undefined' }
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

# The whole run, as one function: Stop-Bootstrap unwinds out of it from any depth, and its
# variables stay its own instead of landing in the caller's session when run as text.
function Invoke-Bootstrap {
    Write-Host ''
    Write-Host '=== Claude Code portable config: bootstrap ===' -ForegroundColor White
    Write-Host "upstream: $UpstreamSlug" -ForegroundColor DarkGray

    # --- Where does this run from, and where does the repo go? ---------------
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
            # GetFolderPath, not "$env:USERPROFILE\Desktop": where OneDrive Known Folder Move
            # is on, it redirects Desktop and the literal path is missing or a stale leftover.
            $desktop = [Environment]::GetFolderPath('Desktop')
            if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
            $Dest = Join-Path $desktop 'claude-config'
        }
    }

    # --- Preflight: everything checked before anything is written ------------
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

    # Claude Code is what this config is FOR, but installing config before the app is a
    # legitimate order to do things in, so a missing claude warns rather than stops.
    if (Have 'claude') { Say '  [ OK ] claude on PATH' 'Green' }
    else { Say '  [WARN] claude not on PATH -- irm https://claude.ai/install.ps1 | iex   (or: winget install Anthropic.ClaudeCode)' 'Yellow' }

    # Node.js is not a Claude Code requirement: the native installer brings no Node, and even
    # the npm package runs a native binary. Node matters only to npm-installed tools, such as
    # Codex CLI, so its absence is worth a line, not a warning.
    if (Have 'node') { Say '  [ OK ] node on PATH (used by npm-installed tools such as Codex CLI)' 'Green' }
    else { Say '  [ -- ] node not on PATH -- only needed for npm-installed tools such as Codex CLI (npm install -g @openai/codex)' 'DarkGray' }

    $policyFix = $false
    $policyBlocked = $false
    $policyScopes = Get-WindowsPowerShellPolicyList
    if ($policyScopes.Count -eq 0) {
        Say '  [WARN] could not read Windows PowerShell''s execution policy -- if it is Restricted, the claude-*/codex-* launchers will not load there' 'Yellow'
    } else {
        $policy = Resolve-ProfilePolicy $policyScopes
        if ($policy.Policy -notin @('Restricted', 'AllSigned')) {
            Say "  [ OK ] Windows PowerShell execution policy: $($policy.Policy) ($($policy.From)) -- profiles load" 'Green'
        } elseif ($policy.From -in @('MachinePolicy', 'UserPolicy')) {
            # Group Policy outranks every scope Set-ExecutionPolicy can write, so there is
            # nothing for this script to fix -- only something to say before it is a mystery.
            $policyBlocked = $true
            Say "  [WARN] Group Policy ($($policy.From)) sets Windows PowerShell's execution policy to $($policy.Policy)." 'Yellow'
            Say '         Its profile will not run, so the claude-*/codex-* launchers will not load in Windows PowerShell.' 'Yellow'
            Say '         Use PowerShell 7 instead (winget install --id Microsoft.PowerShell -e) and make it Windows' 'Yellow'
            Say '         Terminal''s default profile, or ask whoever manages this machine. Installing anyway.' 'Yellow'
        } else {
            $policyFix = $true
            Say "  [WARN] Windows PowerShell execution policy: $($policy.Policy) ($($policy.From)) -- profiles cannot load; the plan below fixes it" 'Yellow'
        }
    }

    # --- Who are we, and is a fork needed at all? ----------------------------
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

    # --- Assess the destination ----------------------------------------------
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

    # --- Plan, then confirm --------------------------------------------------
    Section 'Plan'

    $plan = @()
    if ($willFork)          { $plan += "Fork $UpstreamSlug to $forkSlug" }
    elseif ($ownsUpstream)  { $plan += "Skip the fork -- you own $UpstreamSlug and can already push to it" }
    elseif ($NoFork)        { $plan += 'Skip the fork (-NoFork) -- read-only clone, sync-config push will not work' }
    else                    { $plan += "Use the fork you already have at $forkSlug" }

    if ($rewireRemotes)     { $plan += "Repoint origin at $forkSlug, keeping $UpstreamSlug as upstream" }
    elseif ($reuseExisting) { $plan += "Use the clone already at $Dest" }
    else                    { $plan += "Clone into $Dest" }

    if ($policyFix)         { $plan += "Set Windows PowerShell's CurrentUser execution policy to RemoteSigned (needed for profiles to load)" }

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
            Stop-Bootstrap 0
        }
    }

    # --- Fork ----------------------------------------------------------------
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

    # --- Clone, or rewire an existing clone ----------------------------------
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

    # --- Execution policy ----------------------------------------------------
    # CurrentUser scope: no elevation, and it outranks LocalMachine. Set from 5.1 itself,
    # since that is the edition whose policy is wrong. Set-ExecutionPolicy reports an error
    # AFTER writing the value when a more specific scope overrides it ("updated your
    # execution policy successfully, but the setting is overridden"), as the inherited
    # Process scope does whenever this script was started with -ExecutionPolicy Bypass --
    # so success is judged by reading the policy back, not by the exit code.
    if ($policyFix) {
        Section 'Execution policy'
        $setPolicy = 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force'
        Say "  > powershell.exe -NoProfile -Command `"$setPolicy`"" 'DarkGray' -Plan
        if (-not $DryRun) {
            [void](Invoke-WindowsPowerShell "try { $setPolicy -ErrorAction Stop } catch { }")
            $after = Resolve-ProfilePolicy (Get-WindowsPowerShellPolicyList)
            if ($after.Policy -eq 'RemoteSigned') {
                Say '  [ OK ] Windows PowerShell execution policy is now RemoteSigned (CurrentUser)' 'Green'
            } else {
                Say "  [WARN] the policy is still $($after.Policy) ($($after.From)); the launchers will not load in Windows PowerShell." 'Yellow'
                Say '         In Windows PowerShell, run:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' 'Yellow'
            }
        }
    }

    # --- Deploy --------------------------------------------------------------
    Section 'Deploy'

    $deployScript = Join-Path $Dest 'deploy.ps1'
    if (Test-Path $deployScript) {
        Invoke-RepoScript $deployScript
        $deployCode = $LASTEXITCODE
        if ($deployCode -ne 0) {
            Write-Host ''
            Write-Host "deploy.ps1 failed (exit code $deployCode). It puts back every file it had already written, so" -ForegroundColor Red
            Write-Host "the machine is as it was; the clone at $Dest is kept. Fix the error above, then run" -ForegroundColor Red
            Write-Host 'bootstrap again -- it reuses the clone.' -ForegroundColor Red
            Stop-Bootstrap $deployCode
        }
    } elseif ($DryRun) {
        Say "  would run $deployScript" 'DarkGray' -Plan
    } else {
        Fail @("The clone at $Dest has no deploy.ps1.", "It looks incomplete -- delete it and run bootstrap again.")
    }

    # --- Verify --------------------------------------------------------------
    $doctorScript = Join-Path $Dest 'doctor.ps1'
    $doctorCode = 0
    if ($DryRun) {
        Section 'Verify'
        Say "  would run $doctorScript" 'DarkGray' -Plan
    } elseif (Test-Path $doctorScript) {
        Invoke-RepoScript $doctorScript
        $doctorCode = $LASTEXITCODE
    }

    # --- What to do next -----------------------------------------------------
    Section 'Next'

    if ($DryRun) {
        Write-Host '  Dry run complete -- nothing was written. Re-run without -DryRun to install.' -ForegroundColor Yellow
        Stop-Bootstrap 0
    }

    if ($policyBlocked) {
        Write-Host '  Group Policy keeps Windows PowerShell from loading profiles (see Preflight), so' -ForegroundColor Yellow
        Write-Host '  open PowerShell 7 for the step below.' -ForegroundColor Yellow
    }
    # Here-strings end at column 0, so these two sit outside the indentation.
    Write-Host @"
  1. Open a NEW terminal tab. The claude-* functions only exist in shells started
     after the deploy.
  2. Run:  claude-sp
     Claude Code with the custom system prompt, permissions in auto mode. This is
     the main way in; read the README before trying claude-spsp.
  3. Inside Claude Code, /sync-config and /deep-research-tiered should be in the slash command
     list, and the file-manager agent should be available. The skills behind those
     commands are directories under ~/.claude/skills/, one per command.
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

    if ($doctorCode -ne 0) {
        Write-Host ''
        Write-Host 'doctor.ps1 reported a failure above. The install is on disk but not healthy.' -ForegroundColor Red
        Stop-Bootstrap $doctorCode
    }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
}

$bootstrapExitCode = 0
try {
    Invoke-Bootstrap
} catch {
    # Stop-Bootstrap's marker carries the code. Anything else is a real error: rethrown,
    # so a file run exits non-zero with it and a web run prints it.
    $stopCode = $_.Exception.Data['BootstrapExitCode']
    if ($null -eq $stopCode) { throw }
    $bootstrapExitCode = [int]$stopCode
} finally {
    $ErrorActionPreference = $bootstrapSavedEap
    if ($null -ne $bootstrapSavedNativePref) { $PSNativeCommandUseErrorActionPreference = $bootstrapSavedNativePref }
}

# Run as a file, exit as usual. Run as text, 'exit' would end the user's own session,
# so only record the code, where $LASTEXITCODE (and so 'if ($LASTEXITCODE)') sees it.
if ($PSCommandPath) { exit $bootstrapExitCode }
$global:LASTEXITCODE = $bootstrapExitCode
