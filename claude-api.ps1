# Launch Claude Code in API mode (pay-as-you-go billing)
# Usage:
#   .\claude-api.ps1                    # API mode, default model
#   .\claude-api.ps1 -Extended          # API mode, 1M context
#   .\claude-api.ps1 -SP                # API mode + system prompt
#   .\claude-api.ps1 -SPSP              # API mode + system prompt + skip perms
#   .\claude-api.ps1 -Extended -SP      # API mode + 1M context + system prompt
#   .\claude-api.ps1 -Extended -SPSP    # API mode + 1M context + system prompt + skip perms

param(
    [switch]$Extended,
    [switch]$SP,
    [switch]$SPSP,
    # An alias, not a pinned id: 'opus' always resolves to the current Opus, so this
    # file does not go stale every time a model ships. Pass a full id (for example
    # claude-opus-5) only when a specific version actually matters.
    [string]$Model = "opus"
)

# One decrypt path for the whole repo -- see Get-Secret.ps1. Reimplementing it here
# meant a store this script could not read still looked fine everywhere else.
$env:ANTHROPIC_API_KEY = & (Join-Path $PSScriptRoot "Get-Secret.ps1") -Name api-key

# $PSScriptRoot, not "$env:USERPROFILE\Desktop\claude-config": this script IS in the
# repo, so the prompt file is its neighbour and no path needs guessing. The literal
# Desktop path was also wrong on any machine with OneDrive Known Folder Move enabled
# (the real Desktop is then under OneDrive\), where Get-Content would print an error
# and -SP would go on to launch the session with an empty prompt appended.
$systemPromptPath = Join-Path $PSScriptRoot "System Prompt.txt"

# Build arguments
$args_list = @()

# With no -Model, pass no --model at all, so the session follows whatever
# settings.json selects. Testing the bound parameter rather than comparing against
# the default string means the two can never drift apart.
if ($Extended) {
    $args_list += "--model", "$Model[1m]"
} elseif ($PSBoundParameters.ContainsKey('Model')) {
    $args_list += "--model", $Model
}

if ($SP -or $SPSP) {
    if (-not (Test-Path -LiteralPath $systemPromptPath)) {
        Write-Error "System prompt not found: $systemPromptPath"
        exit 1
    }
    $args_list += "--append-system-prompt", (Get-Content -LiteralPath $systemPromptPath -Raw)
}
if ($SPSP) {
    $args_list += "--dangerously-skip-permissions", "--permission-mode", "dontAsk"
}

Write-Host "Starting Claude Code in API mode" -ForegroundColor Yellow
if ($Extended) { Write-Host "  Extended context: 1M tokens" -ForegroundColor Cyan }
if ($SP -or $SPSP) { Write-Host "  System prompt: loaded" -ForegroundColor Cyan }
if ($SPSP) { Write-Host "  Permissions: skipped" -ForegroundColor Cyan }
Write-Host ""

try {
    claude @args_list
} finally {
    Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
}
