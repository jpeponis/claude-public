# claude-functions.ps1 -- Claude Code shell functions.
#
# Deployed to ~/.claude/claude-functions.ps1 and dot-sourced by a small managed block
# that deploy.ps1 injects into BOTH PowerShell profiles:
#   Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1   (Windows PowerShell 5.1)
#   Documents\PowerShell\Microsoft.PowerShell_profile.ps1          (PowerShell 7+)
#
# Why a separate file instead of syncing a whole profile: replacing a user's profile
# destroys whatever else they keep in it, and syncing only the 5.1 path leaves every
# one of these functions undefined in PowerShell 7. Both problems go away when the
# profile merely sources this file.
#
# Note on --system-prompt vs --append-system-prompt (deliberate, not drift):
#   claude-sp      uses --system-prompt-file        -> REPLACES the default system prompt
#   claude-or-sp   uses --append-system-prompt-file -> APPENDS to the default
# Keep it that way unless you intend to change behaviour.

# --- Where this repo lives ---------------------------------------------------
# Resolved through the machine-local '.config-root' pointer deploy.ps1 writes beside
# this file, so an install anywhere still works. Fallback: <Desktop>\claude-config,
# the bootstrap location -- via GetFolderPath('Desktop'), not "$env:USERPROFILE\Desktop",
# because OneDrive Known Folder Move redirects Desktop on a default Windows 11 setup
# and the literal path is then missing or a stale leftover.
#
# Every function below routes through this one, so the repo's location is decided in
# exactly one place. (codex-sp lives in codex-functions.ps1 under ~/.codex now, with
# its own pointer, so the Codex target no longer depends on this file existing.)
$script:ClaudeFnDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ClaudeConfigRoot = $null
$claudePointer = Join-Path $script:ClaudeFnDir '.config-root'
if (Test-Path $claudePointer) {
    $script:ClaudeConfigRoot = (Get-Content $claudePointer -Raw).Trim()
}
if (-not $script:ClaudeConfigRoot -or -not (Test-Path $script:ClaudeConfigRoot)) {
    $script:ClaudeConfigRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config'
}

function Get-ClaudeConfigPath {
    param([string]$Leaf)
    return (Join-Path $script:ClaudeConfigRoot $Leaf)
}

# --- Encrypted secret store: load GitHub token for the GitHub MCP plugin ---
# The plugin's .mcp.json sends "Authorization: Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}",
# expanded from the environment when Claude Code launches. Load it from the DPAPI
# store (~/.claude/.github-token.enc, created by Set-Secret.ps1) if not already set.
if (-not $env:GITHUB_PERSONAL_ACCESS_TOKEN -and (Test-Path "$env:USERPROFILE\.claude\.github-token.enc")) {
    $env:GITHUB_PERSONAL_ACCESS_TOKEN = & (Get-ClaudeConfigPath "Get-Secret.ps1") -Name github-token
}

function claude-sp {
    claude --system-prompt-file (Get-ClaudeConfigPath "System Prompt.txt") @args
}

function claude-spsp {
    claude-sp --dangerously-skip-permissions --permission-mode dontAsk @args
}

# --- OpenRouter-mode functions (session routed through OpenRouter's Anthropic-
# compatible endpoint; /model lists the OpenRouter catalog via gateway discovery) ---
#
# Replaced the API-mode functions (claude-api*) 2026-08-21: never used, and the slot
# was wanted for OpenRouter. Everything in a claude-or session -- Claude models
# included -- bills the OpenRouter key, not the Pro subscription.

# Delegates to Get-Secret.ps1 rather than repeating its two lines, which is how the
# github-token loader above already does it. Three separate copies of this decrypt
# existed; a store none of them could read still reported as present everywhere.
function Get-OpenRouterKey {
    return & (Get-ClaudeConfigPath "Get-Secret.ps1") -Name openrouter-key
}

function claude-or {
    $key = Get-OpenRouterKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Error "No OpenRouter key. Create it with: Set-Secret.ps1 -Name openrouter-key"
        return
    }
    # A real ANTHROPIC_API_KEY would win precedence over the auth token, so drop any
    # (OpenRouter's docs: the variable must not carry an Anthropic key). Not restored:
    # default-mode shells don't set one.
    Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
    # Tool Search deferral is Anthropic-only: with ENABLE_TOOL_SEARCH inherited from the
    # User env var, requests omit most tool definitions from tools[] for on-demand fetch,
    # and a non-Anthropic model through the gateway 400s ("Deferred custom tools are only
    # supported on Anthropic models..."). Drop it for the child, restore for this shell.
    $ets = $env:ENABLE_TOOL_SEARCH
    Remove-Item Env:\ENABLE_TOOL_SEARCH -ErrorAction SilentlyContinue
    $env:ANTHROPIC_BASE_URL = 'https://openrouter.ai/api'
    $env:ANTHROPIC_AUTH_TOKEN = $key
    # v2.1.129+: populates the /model picker from the gateway's /v1/models.
    $env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'
    try { claude @args }
    finally {
        if ($null -ne $ets) { $env:ENABLE_TOOL_SEARCH = $ets }
        Remove-Item Env:\ANTHROPIC_BASE_URL, Env:\ANTHROPIC_AUTH_TOKEN,
            Env:\CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY -ErrorAction SilentlyContinue
    }
}

function claude-or-sp {
    claude-or --append-system-prompt-file (Get-ClaudeConfigPath "System Prompt.txt") @args
}

function claude-or-spsp {
    claude-or-sp --dangerously-skip-permissions --permission-mode dontAsk @args
}

# codex-sp moved to codex-functions.ps1, deployed to ~/.codex/codex-functions.ps1 and
# sourced by the same managed profile block. The Codex launcher living in the Claude
# target's file meant Codex could not exist without Claude installed -- and its
# hand-written subcommand grammar went stale within one Codex release. Both problems
# leave with it.
