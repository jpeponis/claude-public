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
    [string]$Model = "claude-opus-4-6"
)

# Decrypt the API key
$encrypted = Get-Content "$env:USERPROFILE\.claude\.api-key.enc"
$secure = $encrypted | ConvertTo-SecureString
$env:ANTHROPIC_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
)

# Build arguments
$args_list = @()

if ($Extended) {
    $args_list += "--model", "$Model[1m]"
} elseif ($Model -ne "claude-opus-4-6") {
    $args_list += "--model", $Model
}

if ($SPSP) {
    $sp = Get-Content "$env:USERPROFILE\Desktop\claude-config\System Prompt.txt" -Raw
    $args_list += "--append-system-prompt", $sp
    $args_list += "--dangerously-skip-permissions", "--permission-mode", "dontAsk"
} elseif ($SP) {
    $sp = Get-Content "$env:USERPROFILE\Desktop\claude-config\System Prompt.txt" -Raw
    $args_list += "--append-system-prompt", $sp
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
