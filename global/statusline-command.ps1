# Claude Code statusLine - PowerShell port
# Mirrors Git Bash PS1 colors
# Uses OAuth API for real usage data (matches /usage output)
$ErrorActionPreference = 'SilentlyContinue'
$esc = [char]0x1b

# Read JSON from stdin
$jsonText = [Console]::In.ReadToEnd()
$data = $jsonText | ConvertFrom-Json

# Current directory (shorten with ~)
$cwd = if ($data.workspace.current_dir) { $data.workspace.current_dir } elseif ($data.cwd) { $data.cwd } else { '' }
$cwd = $cwd -replace '\\', '/'
$homeDir = $env:USERPROFILE -replace '\\', '/'
if ($homeDir -and $cwd.StartsWith($homeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    $cwd = '~' + $cwd.Substring($homeDir.Length)
}

# Git branch
$gitBranch = ''
$gitDir = if ($data.workspace.current_dir) { $data.workspace.current_dir } elseif ($data.cwd) { $data.cwd } else { '.' }
try {
    $isGit = & git -C $gitDir --no-optional-locks rev-parse --is-inside-work-tree 2>$null
    if ($isGit -eq 'true') {
        $branch = & git -C $gitDir --no-optional-locks symbolic-ref --short HEAD 2>$null
        if (-not $branch) {
            $branch = & git -C $gitDir --no-optional-locks rev-parse --short HEAD 2>$null
        }
        if ($branch) { $gitBranch = " ($branch)" }
    }
} catch {}

# MSYSTEM label
$msystem = if ($env:MSYSTEM) { $env:MSYSTEM } else { 'MINGW64' }

# --- OAuth Usage API (cached to avoid hammering the endpoint) ---
$usageStr = ''
$resetStr = ''
$cachePath = Join-Path $env:USERPROFILE '.claude\.usage-cache.json'
$cacheMaxAge = 60  # seconds between API calls

$usageData = $null
$cacheValid = $false

# Try reading cache
if (Test-Path $cachePath) {
    try {
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
        $cacheAge = ((Get-Date) - [datetime]::Parse($cache.fetched_at)).TotalSeconds
        if ($cacheAge -lt $cacheMaxAge) {
            $usageData = $cache
            $cacheValid = $true
        }
    } catch {}
}

# Fetch fresh data if cache is stale
if (-not $cacheValid) {
    try {
        $credsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        if (Test-Path $credsPath) {
            $creds = Get-Content $credsPath -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            $headers = @{
                'Authorization'  = "Bearer $token"
                'anthropic-beta' = 'oauth-2025-04-20'
                'Content-Type'   = 'application/json'
            }
            $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
                                      -Method GET -Headers $headers -TimeoutSec 5
            $usageData = @{
                utilization = $resp.five_hour.utilization
                resets_at   = $resp.five_hour.resets_at
                fetched_at  = (Get-Date).ToString('o')
            }
            # Write cache
            $usageData | ConvertTo-Json | Set-Content $cachePath -Force
        }
    } catch {}
}

# Format usage percentage (color-coded)
if ($usageData -and $null -ne $usageData.utilization) {
    $pctInt = [math]::Round([double]$usageData.utilization)
    $pctColor = switch ($true) {
        ($pctInt -ge 90) { "$esc[31m"; break }
        ($pctInt -ge 75) { "$esc[38;5;208m"; break }
        ($pctInt -ge 50) { "$esc[33m"; break }
        default          { "$esc[37m" }
    }
    $usageStr = "${pctColor}${pctInt}%$esc[0m"
}

# Format reset timer
if ($usageData -and $usageData.resets_at) {
    try {
        $resetTime = [DateTimeOffset]::Parse($usageData.resets_at).LocalDateTime
        $remaining = ($resetTime - (Get-Date)).TotalSeconds
        if ($remaining -gt 0) {
            $h = [math]::Floor($remaining / 3600)
            $m = [math]::Floor(($remaining % 3600) / 60)
            $resetStr = "$esc[36m${h}h${m}m$esc[0m"
        } else {
            $resetStr = "$esc[32mreset$esc[0m"
        }
    } catch {}
}

# Context window fill (separate from API usage)
$ctxStr = ''
if ($null -ne $data.context_window -and $null -ne $data.context_window.used_percentage) {
    $ctxPct = [math]::Round([double]$data.context_window.used_percentage)
    $ctxColor = switch ($true) {
        ($ctxPct -ge 90) { "$esc[31m"; break }
        ($ctxPct -ge 75) { "$esc[38;5;208m"; break }
        ($ctxPct -ge 50) { "$esc[33m"; break }
        default          { "$esc[37m" }
    }
    $ctxStr = "${ctxColor}ctx:${ctxPct}%$esc[0m"
}

# Build stats segment
$parts = @($usageStr, $resetStr, $ctxStr) | Where-Object { $_ }
$statsSeg = if ($parts.Count -gt 0) { ' [' + ($parts -join ' | ') + ']' } else { '' }

# Output (mirrors PS1 colors: green=user@host, purple=MSYSTEM, yellow=cwd, cyan=branch)
$user = $env:USERNAME
$hostShort = $env:COMPUTERNAME.Split('.')[0]

[Console]::Write(
    "$esc[32m${user}@${hostShort} $esc[35m${msystem} $esc[33m${cwd}$esc[36m${gitBranch}$esc[0m${statsSeg}"
)
