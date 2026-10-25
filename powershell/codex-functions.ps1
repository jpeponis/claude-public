# codex-functions.ps1 -- Codex CLI shell functions.
#
# Deployed to ~/.codex/codex-functions.ps1 and dot-sourced by the same managed profile
# block that sources claude-functions.ps1. Deliberately SEPARATE from that file and
# deployed under ~/.codex, so the Codex target works without the Claude target being
# installed -- the launchers used to live together, which made codex-sp undefined on
# any machine that deployed only Codex.
#
# The repo is resolved through the machine-local '.config-root' pointer deploy.ps1
# writes beside this file, falling back to <Desktop>\claude-config (the bootstrap
# location) when the pointer is absent. Never hardcode the Desktop path in a function:
# it is wrong the moment the repo lives anywhere else, and the failure is silent.
#
# $global:, not $script:. The profile runs in the global scope, so $script: worked at
# the prompt -- but a function resolves $script: in its CALLER's script scope, which
# inside any .ps1 is that script's own, empty one, and codex-sp failed with "Prompt file
# not found". The try/catch is because this runs at every shell start: a throw here (an
# empty or unreadable pointer, say) would abort the rest of the profile.
$global:CodexFnDir = $null
$global:CodexConfigRoot = $null
try {
    $global:CodexFnDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $codexPointer = Join-Path $global:CodexFnDir '.config-root'
    if (Test-Path -LiteralPath $codexPointer) {
        $global:CodexConfigRoot = "$(Get-Content -LiteralPath $codexPointer -Raw)".Trim()
    }
    if (-not $global:CodexConfigRoot -or -not (Test-Path -LiteralPath $global:CodexConfigRoot)) {
        $global:CodexConfigRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config'
    }
} catch {
    Write-Warning "codex-functions.ps1: could not resolve the config repo: $($_.Exception.Message)"
}

# codex-sp: Codex with the repo's custom prompt REPLACING the built-in instructions,
# and the portable 'personal' profile layered on (~/.codex/personal.config.toml,
# deployed from the repo).
#
# Two things to know before reaching for this:
#   - Replacement is explicitly discouraged by the Codex config schema ("STRONGLY
#     DISCOURAGED ... will likely degrade model performance"). codex-sp is the
#     experimental variant; plain `codex` is the control. When behavior looks off,
#     compare against the control before blaming the task.
#   - Profiles are CLI-flag-only (verified on 0.149.0: a `profile` key in config.toml
#     is rejected as legacy). Direct `codex` launches and the IDE never see the
#     personal profile; only this wrapper applies it.
#
# No hand-written subcommand grammar here, on purpose. The old wrapper parsed argv to
# decide where --strict-config was legal and drifted stale within one Codex release
# (agents/queue/migrate-rollouts were unknown to it). Strict validation of the profile
# is doctor.ps1's job, once per version -- not this function's job on every launch.
function codex-sp {
    $promptPath = Join-Path $global:CodexConfigRoot 'System Prompt.txt'

    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
        Write-Error "Prompt file not found: $promptPath"
        return
    }
    $promptContents = Get-Content -LiteralPath $promptPath -Raw
    if ([string]::IsNullOrWhiteSpace($promptContents)) {
        Write-Error "Prompt file is empty: $promptPath"
        return
    }

    # Encode the Windows path as a TOML string for Codex's --config flag.
    $tomlPath = $promptPath.Replace('\', '\\').Replace('"', '\"')
    $configOverride = 'model_instructions_file="' + $tomlPath + '"'

    & codex --profile personal --config $configOverride @args
}
