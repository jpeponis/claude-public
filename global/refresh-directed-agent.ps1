# refresh-directed-agent.ps1 -- SessionStart hook: rebuild ~/.claude/agents/directed.md
# from the repo's "System Prompt.txt" + directed-agent\directed.head.md when either changed.
#
# Why a hook, when collect.ps1 already rebuilds the repo copy: the directed agent IS the
# system prompt, and "System Prompt.txt" is edited in the repo (repo-native, never
# deployed). Without this, the agent a session spawns would lag the prompt until the next
# push AND deploy. Two callers: the claude-sp / claude-or shell functions run it before
# launching (exact), and a SessionStart hook in settings.json runs it for sessions started
# any other way -- one build late for those, since Claude Code reads agent definitions
# before its SessionStart hooks fire (verified on 2.1.250). Same builder as collect.ps1,
# so the repo copy and the deployed copy cannot disagree on content.
#
# SILENT on success. Claude Code injects a SessionStart hook's stdout into the model's
# context, so anything printed here would cost tokens on every session. Failures go to
# stderr with exit 2, which the CLI shows to the user without blocking the session.
$ErrorActionPreference = 'Stop'
try {
    $claudeHome = Split-Path -Parent $MyInvocation.MyCommand.Path

    # Same repo discovery as claude-functions.ps1: the '.config-root' pointer deploy.ps1
    # writes beside this file, then the bootstrap location (OneDrive-aware Desktop).
    $repoRoot = $null
    $pointer = Join-Path $claudeHome '.config-root'
    if (Test-Path $pointer) { $repoRoot = (Get-Content $pointer -Raw).Trim() }
    if (-not $repoRoot -or -not (Test-Path $repoRoot)) {
        $repoRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-config'
    }
    $lib = Join-Path $repoRoot 'lib\Common.ps1'
    if (-not (Test-Path $lib)) {
        throw "config repo not found at $repoRoot (no lib\Common.ps1); run deploy.ps1 so the .config-root pointer is written"
    }
    . $lib

    $plan = Get-ArtifactManifest -ClaudeHome $claudeHome `
                                 -CodexHome  (Join-Path $env:USERPROFILE '.codex') `
                                 -AgentsHome (Join-Path $env:USERPROFILE '.agents') `
                                 -DesktopDir (Get-DesktopPath)
    $configRoot = Get-ConfigRoot -RepoRoot $repoRoot
    $desktopTok = Get-DesktopToken

    foreach ($a in @($plan.Files | Where-Object { $_.Builder -eq 'agent' })) {
        $built = Expand-Tokens -Text (Get-GeneratedArtifactContent -RepoRoot $repoRoot -Artifact $a) `
                               -UserName $env:USERNAME -ConfigRoot $configRoot -Desktop $desktopTok
        foreach ($dest in @($a.Destinations)) {
            $current = $null
            if (Test-Path $dest) { $current = Get-Content $dest -Raw -Encoding UTF8 }
            if ($current -ne $built) { Write-TextFile -Path $dest -Content $built }
        }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("refresh-directed-agent: $($_.Exception.Message)")
    exit 2
}
