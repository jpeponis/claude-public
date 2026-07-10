function claude-sp {
    claude --system-prompt-file "$env:USERPROFILE\Desktop\claude-config\System Prompt.txt" @args
}

function claude-spsp {
    claude-sp --dangerously-skip-permissions --permission-mode dontAsk @args
}

# --- API-mode functions (pay-as-you-go billing, enables 1M context) ---

function Get-AnthropicApiKey {
    $encrypted = Get-Content "$env:USERPROFILE\.claude\.api-key.enc"
    $secure = $encrypted | ConvertTo-SecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
}

function claude-api {
    $env:ANTHROPIC_API_KEY = Get-AnthropicApiKey
    try { claude @args }
    finally { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
}

function claude-api-sp {
    $env:ANTHROPIC_API_KEY = Get-AnthropicApiKey
    try {
        claude --append-system-prompt-file "$env:USERPROFILE\Desktop\claude-config\System Prompt.txt" @args
    }
    finally { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
}

function claude-api-spsp {
    claude-api-sp --dangerously-skip-permissions --permission-mode dontAsk @args
}

function codex-sp {
    $codexArgs = @($args)

    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $promptPath = Join-Path $desktopPath 'claude-config\System Prompt.txt'

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
