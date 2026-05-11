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
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$CodexArgs
    )

    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $promptPath = Join-Path $desktopPath 'claude-config\System Prompt.txt'

    if (-not (Test-Path -LiteralPath $promptPath)) {
        Write-Error "Prompt file not found: $promptPath"
        return
    }

    $developerInstructions = Get-Content -LiteralPath $promptPath -Raw

    if ([string]::IsNullOrWhiteSpace($developerInstructions)) {
        Write-Error "Prompt file is empty: $promptPath"
        return
    }

    & codex --config "developer_instructions=$developerInstructions" @CodexArgs
}
