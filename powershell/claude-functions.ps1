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
#   claude-api-sp  uses --append-system-prompt-file -> APPENDS to the default
# Keep it that way unless you intend to change behaviour.

# --- Where this repo lives ---------------------------------------------------
# GetFolderPath('Desktop'), not "$env:USERPROFILE\Desktop": OneDrive Known Folder
# Move redirects Desktop on a default Windows 11 consumer setup, so the literal path
# is either missing or a stale leftover -- and claude-sp would go looking for the
# system prompt in a directory that does not exist.
#
# Every function below routes through this one, so the repo's location is decided in
# exactly one place. codex-sp used to resolve Desktop itself, which is how the two
# could have disagreed.
#
# This assumes the repo sits at <Desktop>\claude-config, which is where bootstrap.ps1
# and the README put it. Installing anywhere else (bootstrap.ps1 -Dest) would need
# deploy.ps1 to template the path in, the way it already does for {{USERNAME}}.
function Get-ClaudeConfigPath {
    param([string]$Leaf)
    return (Join-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config') $Leaf)
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

# --- API-mode functions (pay-as-you-go billing, enables 1M context) ---

# Delegates to Get-Secret.ps1 rather than repeating its two lines, which is how the
# github-token loader above already does it. Three separate copies of this decrypt
# existed; a store none of them could read still reported as present everywhere.
function Get-AnthropicApiKey {
    return & (Get-ClaudeConfigPath "Get-Secret.ps1") -Name api-key
}

function claude-api {
    $env:ANTHROPIC_API_KEY = Get-AnthropicApiKey
    try { claude @args }
    finally { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
}

function claude-api-sp {
    $env:ANTHROPIC_API_KEY = Get-AnthropicApiKey
    try {
        claude --append-system-prompt-file (Get-ClaudeConfigPath "System Prompt.txt") @args
    }
    finally { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
}

function claude-api-spsp {
    claude-api-sp --dangerously-skip-permissions --permission-mode dontAsk @args
}

function codex-sp {
    $codexArgs = @($args)

    $promptPath = Get-ClaudeConfigPath "System Prompt.txt"

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

    # Codex 0.144 rejects root --strict-config for administrative/debug
    # subcommands. Apply it to interactive, agent, and session commands.
    $rootOptionsWithValue = @(
        '-c', '--config', '--enable', '--disable', '--remote',
        '--remote-auth-token-env', '-i', '--image', '-m', '--model',
        '--local-provider', '-p', '--profile', '-s', '--sandbox', '-C',
        '--cd', '--add-dir', '-a', '--ask-for-approval'
    )
    $knownSubcommands = @(
        'exec', 'e', 'review', 'login', 'logout', 'mcp', 'plugin', 'mcp-server',
        'app-server', 'remote-control', 'app', 'completion', 'update',
        'doctor', 'sandbox', 'debug', 'apply', 'a', 'resume', 'archive',
        'delete', 'unarchive', 'fork', 'cloud', 'cloud-tasks', 'exec-server',
        'features', 'help'
    )
    $strictConfigSubcommands = @(
        'exec', 'e', 'review', 'mcp-server', 'exec-server', 'resume', 'archive',
        'delete', 'unarchive', 'fork', 'doctor'
    )

    $selectedSubcommand = $null
    for ($i = 0; $i -lt $codexArgs.Count; $i++) {
        $argument = [string]$codexArgs[$i]
        if ($argument -eq '--') {
            break
        }
        if ($rootOptionsWithValue -contains $argument) {
            $i++
            continue
        }
        if ($argument.StartsWith('-')) {
            continue
        }
        if ($knownSubcommands -contains $argument) {
            $selectedSubcommand = $argument
        }
        break
    }

    $codexLaunchArgs = @('--config', $configOverride)
    if ($null -eq $selectedSubcommand -or $strictConfigSubcommands -contains $selectedSubcommand) {
        $codexLaunchArgs = @('--strict-config') + $codexLaunchArgs
    }
    $codexLaunchArgs += $codexArgs

    & codex @codexLaunchArgs
}
