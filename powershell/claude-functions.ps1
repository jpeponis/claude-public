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
#
# Nothing here decrypts a secret or touches the environment at shell start: every new
# window runs this file, so the load-time code below only resolves two paths, and it
# cannot throw (a throw here aborts the rest of the profile).

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
#
# $global:, not $script:. The profile runs in the global scope, so $script: worked at
# the prompt -- but a function resolves $script: in its CALLER's script scope, which
# inside any .ps1 is that script's own, empty one: `claude-sp --version` from a script
# ran `claude --system-prompt-file --version`.
$global:ClaudeFnDir = $null
$global:ClaudeConfigRoot = $null
try {
    $global:ClaudeFnDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $claudePointer = Join-Path $global:ClaudeFnDir '.config-root'
    if (Test-Path -LiteralPath $claudePointer) {
        $global:ClaudeConfigRoot = "$(Get-Content -LiteralPath $claudePointer -Raw)".Trim()
    }
    if (-not $global:ClaudeConfigRoot -or -not (Test-Path -LiteralPath $global:ClaudeConfigRoot)) {
        $global:ClaudeConfigRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config'
    }
} catch {
    Write-Warning "claude-functions.ps1: could not resolve the config repo: $($_.Exception.Message)"
}

function Get-ClaudeConfigPath {
    param([string]$Leaf)
    return (Join-Path $global:ClaudeConfigRoot $Leaf)
}

# --- GitHub token: per launch, and only for the GitHub plugin -----------------
# The plugin's .mcp.json sends "Authorization: Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}",
# expanded from the environment when Claude Code launches. This used to be decrypted
# at every shell start and exported, so every process started from any PowerShell
# window inherited it, plugin enabled or not. Now the launchers call this just before
# `claude` and put the variable back as they found it afterwards. It sets the token
# only when all of these hold:
#   - the user has not set GITHUB_PERSONAL_ACCESS_TOKEN (theirs is left untouched);
#   - ~/.claude/.github-token.enc exists (created by Set-Secret.ps1);
#   - ~/.claude/settings.json has enabledPlugins."github@claude-plugins-official" true.
#     User settings only: a plugin enabled solely in a project's settings gets no token.
# A token that will not decrypt is a warning, never a failed launch.
function Import-GitHubToken {
    if ($env:GITHUB_PERSONAL_ACCESS_TOKEN) { return }
    $claudeHome = Join-Path $env:USERPROFILE '.claude'
    if (-not (Test-Path -LiteralPath (Join-Path $claudeHome '.github-token.enc'))) { return }
    try {
        $settings = Get-Content -LiteralPath (Join-Path $claudeHome 'settings.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json
        if ($settings.enabledPlugins.'github@claude-plugins-official' -ne $true) { return }
    } catch { return }
    # Get-Secret reports a failure on stderr and returns nothing; the catch is for the
    # unexpected (Get-Secret.ps1 itself missing).
    $token = $null
    try { $token = & (Get-ClaudeConfigPath "Get-Secret.ps1") -Name github-token } catch { }
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Warning "GitHub plugin is enabled but github-token did not decrypt; starting claude without GITHUB_PERSONAL_ACCESS_TOKEN."
        return
    }
    $env:GITHUB_PERSONAL_ACCESS_TOKEN = $token
}

# The directed and research-worker agents are "System Prompt.txt" wearing frontmatter,
# built into ~/.claude/agents by refresh-directed-agent.ps1 (deployed beside this file).
# It runs here, BEFORE the launch: Claude Code reads agent definitions before its
# SessionStart hooks fire (verified on 2.1.250), so the hook alone leaves the first
# session after a prompt edit one build behind. Silent when nothing changed.
function Update-DirectedAgents {
    $refresh = Join-Path $global:ClaudeFnDir 'refresh-directed-agent.ps1'
    if (Test-Path $refresh) { & $refresh }
}

function claude-sp {
    Update-DirectedAgents
    $savedToken = $env:GITHUB_PERSONAL_ACCESS_TOKEN
    try {
        Import-GitHubToken
        claude --system-prompt-file (Get-ClaudeConfigPath "System Prompt.txt") @args
    }
    finally {
        # Remove-Item, not SetEnvironmentVariable($name, $null): on PowerShell 7 that stores
        # an empty string instead of deleting the variable, and every later child inherits it.
        if ($null -eq $savedToken) { Remove-Item -LiteralPath 'Env:GITHUB_PERSONAL_ACCESS_TOKEN' -ErrorAction SilentlyContinue }
        else { $env:GITHUB_PERSONAL_ACCESS_TOKEN = $savedToken }
    }
}

# Bypass mode and nothing more. It used to add --permission-mode dontAsk too, which did
# nothing: with --dangerously-skip-permissions present the session is bypassPermissions
# whatever the flag order (tested on 2.1.310). Had that precedence ever flipped, dontAsk
# would have silently denied every tool not on the allowlist.
function claude-spsp {
    claude-sp --dangerously-skip-permissions @args
}

# --- OpenRouter-mode functions (session routed through OpenRouter's Anthropic-
# compatible endpoint; /model lists the OpenRouter catalog via gateway discovery) ---
#
# Replaced the API-mode functions (claude-api*) 2026-08-21: never used, and the slot
# was wanted for OpenRouter. Everything in a claude-or session -- Claude models
# included -- bills the OpenRouter key, not the Pro subscription.

# Delegates to Get-Secret.ps1 rather than repeating its two lines, as Import-GitHubToken
# does. Three separate copies of this decrypt existed; a store none of them could read
# still reported as present everywhere. On failure Get-Secret prints its reason to
# stderr and returns nothing, which claude-or's empty-key guard catches.
function Get-OpenRouterKey {
    return & (Get-ClaudeConfigPath "Get-Secret.ps1") -Name openrouter-key
}

function claude-or {
    Update-DirectedAgents
    $key = Get-OpenRouterKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Error "No usable OpenRouter key. Create it with: Set-Secret.ps1 -Name openrouter-key"
        return
    }
    # Every variable changed below is saved first and put back exactly as it was in
    # `finally`, so a value set in this shell survives the session (ANTHROPIC_BASE_URL
    # and the discovery flag used to be deleted outright).
    #   ANTHROPIC_API_KEY: a real key would win precedence over the auth token, so it is
    #     dropped for the child (OpenRouter's docs: the variable must not carry an
    #     Anthropic key).
    #   ENABLE_TOOL_SEARCH: Tool Search deferral is Anthropic-only. With it inherited from
    #     the User env var, requests omit most tool definitions from tools[] for
    #     on-demand fetch, and a non-Anthropic model through the gateway 400s ("Deferred
    #     custom tools are only supported on Anthropic models...").
    #   CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY: v2.1.129+, populates the /model picker
    #     from the gateway's /v1/models.
    $touched = 'ANTHROPIC_API_KEY', 'ENABLE_TOOL_SEARCH', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN',
        'CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY', 'GITHUB_PERSONAL_ACCESS_TOKEN'
    $saved = @{}
    foreach ($name in $touched) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        Remove-Item Env:\ANTHROPIC_API_KEY, Env:\ENABLE_TOOL_SEARCH -ErrorAction SilentlyContinue
        $env:ANTHROPIC_BASE_URL = 'https://openrouter.ai/api'
        $env:ANTHROPIC_AUTH_TOKEN = $key
        $env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'
        Import-GitHubToken
        claude @args
    }
    finally {
        # Remove-Item for a variable that was unset before: SetEnvironmentVariable($name, $null)
        # leaves an empty string behind on PowerShell 7.
        foreach ($name in $touched) {
            if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
        }
    }
}

function claude-or-sp {
    claude-or --append-system-prompt-file (Get-ClaudeConfigPath "System Prompt.txt") @args
}

# Bypass only; see claude-spsp for why dontAsk is gone.
function claude-or-spsp {
    claude-or-sp --dangerously-skip-permissions @args
}

# codex-sp moved to codex-functions.ps1, deployed to ~/.codex/codex-functions.ps1 and
# sourced by the same managed profile block. The Codex launcher living in the Claude
# target's file meant Codex could not exist without Claude installed -- and its
# hand-written subcommand grammar went stale within one Codex release. Both problems
# leave with it.
