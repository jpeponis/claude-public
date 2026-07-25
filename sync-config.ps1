# sync-config.ps1 -- Unified push/pull for Claude Code config repo
# Usage:
#   sync-config.ps1 pull                  Pull from remote and deploy to local machine
#   sync-config.ps1 pull -DryRun          Pull, then preview the deploy without writing anything
#   sync-config.ps1 push -DryRun          Collect local config, stage, show what would be committed
#   sync-config.ps1 push                  Collect, stage, commit, and push to remote
#
# Designed to run from any machine. Username parameterization is handled by
# collect.ps1 (local -> {{USERNAME}}) and deploy.ps1 ({{USERNAME}} -> local).

param(
    [Parameter(Position = 0)]
    [ValidateSet("push", "pull")]
    [string]$Action = "pull",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Fail fast instead of hanging on an interactive credential/TTY prompt when run
# non-interactively (e.g. from Claude Code). Credentials still come from Git
# Credential Manager; this only disables the interactive fallback.
$env:GIT_TERMINAL_PROMPT = "0"

# --- Validate repo state ---
if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
    Write-Host "ERROR: $repoRoot is not a git repository." -ForegroundColor Red
    exit 1
}

function Invoke-Pull {
    param([bool]$DryRun)

    Write-Host "=== PULL $(if ($DryRun) {'(dry run) '})===" -ForegroundColor Cyan

    # Fetch and pull
    Write-Host "Pulling from origin/main..." -ForegroundColor White
    git -C $repoRoot pull origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git pull failed." -ForegroundColor Red
        exit 1
    }

    # Deploy. -DryRun previews every local write without performing any -- worth using
    # on a machine whose existing config you have not inspected yet.
    Write-Host ""
    & (Join-Path $repoRoot "deploy.ps1") -DryRun:$DryRun

    # Then report actual state. deploy.ps1 can only tell you what it wrote; doctor.ps1
    # checks what is true afterwards, which is where silent mismatches show up.
    if (-not $DryRun) {
        $doctor = Join-Path $repoRoot "doctor.ps1"
        if (Test-Path $doctor) {
            Write-Host ""
            & $doctor
        }
    }
}

function Invoke-Push {
    param([bool]$DryRun)

    Write-Host "=== PUSH $(if ($DryRun) {'(dry run) '})===" -ForegroundColor Cyan

    # Pull first to avoid conflicts
    Write-Host "Pulling latest before push..." -ForegroundColor White
    git -C $repoRoot pull origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git pull failed. Resolve conflicts before pushing." -ForegroundColor Red
        exit 1
    }

    # Collect local config into repo
    Write-Host ""
    & (Join-Path $repoRoot "collect.ps1")

    # Stage everything
    Write-Host ""
    git -C $repoRoot add -A

    # Check for changes
    $status = git -C $repoRoot status --porcelain
    if (-not $status) {
        Write-Host ""
        Write-Host "Nothing to commit. Local config matches repo." -ForegroundColor Green
        exit 0
    }

    # Show what changed
    Write-Host ""
    Write-Host "Staged changes:" -ForegroundColor Cyan
    git -C $repoRoot status --short
    Write-Host ""

    if ($DryRun) {
        Write-Host "Dry run complete. Run without -DryRun to commit and push." -ForegroundColor Yellow
        # Unstage only -- leave working tree as-is (next push re-collects anyway).
        #
        # Redirecting a native command's stderr turns each line into a PowerShell error
        # record, and with $ErrorActionPreference = 'Stop' (set at the top of this file)
        # that record is TERMINATING. Every redirection form does it -- '2>&1 | Out-Null',
        # '2>$null', and '(& cmd) 2>$null' all throw; only leaving stderr alone is safe.
        # So any message git chose to write here would abort the dry run one line before
        # its clean exit. Relax the preference for exactly this call.
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { git -C $repoRoot reset HEAD -- . 2>&1 | Out-Null }
        finally { $ErrorActionPreference = $previousEap }
        exit 0
    }

    # Commit and push
    $date = Get-Date -Format "yyyy-MM-dd"
    $msg = "Update config from $env:COMPUTERNAME on $date"
    git -C $repoRoot commit -m $msg
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git commit failed." -ForegroundColor Red
        exit 1
    }

    git -C $repoRoot push origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git push failed." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "Pushed successfully." -ForegroundColor Green
}

# --- Dispatch ---
switch ($Action) {
    "pull" { Invoke-Pull -DryRun $DryRun.IsPresent }
    "push" { Invoke-Push -DryRun $DryRun.IsPresent }
}
