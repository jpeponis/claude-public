# apply-terminal-keybinding.ps1 -- Ensure Windows Terminal sends a newline on Shift+Enter
#
# Repo-native (like claude-api.ps1): NOT collected from any machine. It injects a fixed,
# known action + keybinding into whatever Windows Terminal settings.json exists locally.
#
# Why injection instead of whole-file sync:
#   WT settings.json holds machine-specific profile GUIDs and lives under a package path
#   that differs across machines (stable / Preview / unpackaged). Syncing the whole file
#   would clobber per-machine terminal config. So we only add two small, idempotent blocks.
#
# What it adds:
#   - action  "User.sendInput.ShiftEnterNewline"  ->  sendInput "\u001b\r"  (ESC + CR)
#   - keybinding  shift+enter  ->  that action
#   Claude Code reads ESC+CR (Meta/Alt+Enter) as "insert newline", not "submit".
#
# Safe to run repeatedly: if the action id is already present, the file is left untouched.

[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$actionId = "User.sendInput.ShiftEnterNewline"

# --- Snippets (single-quoted here-strings: backslashes stay literal, e.g. \u001b\r) ---
$actionItem = @'
        {
            "command":
            {
                "action": "sendInput",
                "input": "\u001b\r"
            },
            "id": "User.sendInput.ShiftEnterNewline"
        }
'@

$keybindingItem = @'
        {
            "id": "User.sendInput.ShiftEnterNewline",
            "keys": "shift+enter"
        }
'@

# NOTE: Get-TerminalSettingsPaths and Test-JsonValid now live in lib\Common.ps1
# (shared with doctor.ps1), dot-sourced above.

# --- Insert an item at the head of a top-level array; returns $null if the key is absent ---
function Add-ToArray {
    param([string]$Json, [string]$Key, [string]$ItemText)

    $rx = [regex]"(?s)(""$Key""\s*:\s*\[)"
    $m = $rx.Match($Json)
    if (-not $m.Success) { return $null }

    $pos  = $m.Index + $m.Length
    $rest = $Json.Substring($pos)
    if ($rest -match '^\s*\]') {
        # Empty array: insert item with no trailing comma
        $block = "`n" + $ItemText + "`n    "
    } else {
        # Non-empty: insert item + comma before the existing first element
        $block = "`n" + $ItemText + ","
    }
    return $Json.Substring(0, $pos) + $block + $Json.Substring($pos)
}

# --- Add a missing top-level key (with its array) right after the opening brace ---
function Add-TopLevelArrayKey {
    param([string]$Json, [string]$Key, [string]$ItemText)

    $block = "    ""$Key"":`n    [`n" + $ItemText + "`n    ],"
    $idx = $Json.IndexOf('{')
    if ($idx -lt 0) { return $null }
    return $Json.Substring(0, $idx + 1) + "`n" + $block + $Json.Substring($idx + 1)
}

$paths = @(Get-TerminalSettingsPaths)
if ($paths.Count -eq 0) {
    Write-Host "[SKIP] Windows Terminal settings.json not found (Terminal may not be installed)." -ForegroundColor Yellow
    return
}

foreach ($path in $paths) {
    $label = $path.Replace($env:LOCALAPPDATA, '%LOCALAPPDATA%')
    try {
        $json = Get-Content $path -Raw -Encoding UTF8

        if ($json -match [regex]::Escape($actionId)) {
            Write-Host "[OK]   Shift+Enter binding already present -> $label" -ForegroundColor Green
            continue
        }

        # Insert action
        $updated = Add-ToArray -Json $json -Key 'actions' -ItemText $actionItem
        if ($null -eq $updated) {
            $updated = Add-TopLevelArrayKey -Json $json -Key 'actions' -ItemText $actionItem
        }
        # Insert keybinding
        $updated2 = Add-ToArray -Json $updated -Key 'keybindings' -ItemText $keybindingItem
        if ($null -eq $updated2) {
            $updated2 = Add-TopLevelArrayKey -Json $updated -Key 'keybindings' -ItemText $keybindingItem
        }

        if ($null -eq $updated2 -or -not (Test-JsonValid $updated2)) {
            Write-Host "[WARN] Could not safely edit $label (unexpected structure). Left unchanged." -ForegroundColor Yellow
            continue
        }

        if ($DryRun) {
            Write-Host "[DRY]  Would add Shift+Enter newline binding -> $label" -ForegroundColor Green
            continue
        }

        # Back up next to the repo, then write
        $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $backupDir = Join-Path $repoRoot ".backups\terminal\$stamp"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item $path (Join-Path $backupDir "settings.json") -Force

        Write-TextFile -Path $path -Content $updated2
        Write-Host "[OK]   Added Shift+Enter newline binding -> $label" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Failed to update $label : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
