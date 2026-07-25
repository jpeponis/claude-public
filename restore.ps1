# restore.ps1 -- Put backed-up files from .backups\<stamp>\ back where they came from.
# Usage:
#   powershell -ExecutionPolicy Bypass -File restore.ps1                    # list backups (default)
#   powershell -ExecutionPolicy Bypass -File restore.ps1 -Latest -DryRun    # preview newest restorable
#   powershell -ExecutionPolicy Bypass -File restore.ps1 -Latest            # restore newest restorable
#   powershell -ExecutionPolicy Bypass -File restore.ps1 -Timestamp 2026-07-25_154349
#
# deploy.ps1 writes a manifest.json (Label -> Dest) into every backup directory it
# creates, and this script restores exactly what that manifest records -- nothing
# else. Backup directories without a manifest (made before manifests existed, or
# holding only profile snapshots) are refused rather than guessed at; their files
# stay on disk for restoring by hand.
#
# Exit code: 0 on success (including list mode), 1 on refusal or bad arguments.

[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Latest,
    [string]$Timestamp,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "lib\Common.ps1")

$backupsRoot = Join-Path $repoRoot ".backups"

function Say {
    param([string]$Text, [string]$Color = 'Gray', [switch]$Plan)
    $prefix = if ($DryRun -and $Plan) { "[DRY] " } else { "" }
    Write-Host "$prefix$Text" -ForegroundColor $Color
}

function Fail {
    param([string[]]$Lines)
    foreach ($l in $Lines) { Write-Host $l -ForegroundColor Red }
    exit 1
}

function Get-ManifestPath { param($Dir) Join-Path $Dir.FullName "manifest.json" }

# --- Argument sanity ---------------------------------------------------------
$restoring = $Latest -or -not [string]::IsNullOrEmpty($Timestamp)

if ($Latest -and $Timestamp)      { Fail "Use -Latest or -Timestamp <stamp>, not both." }
if ($List -and $restoring)        { Fail "-List cannot be combined with -Latest or -Timestamp." }
if ($DryRun -and -not $restoring) { Fail "-DryRun previews a restore; pair it with -Latest or -Timestamp <stamp>." }

# --- Enumerate backups (stamp names are zero-padded, so name order = age order) ---
$dirs = @()
if (Test-Path $backupsRoot) {
    $dirs = @(Get-ChildItem $backupsRoot -Directory | Sort-Object Name -Descending)
}

if ($dirs.Count -eq 0) {
    if ($restoring) { Fail "No backups found in $backupsRoot -- nothing to restore." }
    Say "No backups found in $backupsRoot" 'Yellow'
    Say "deploy.ps1 creates one automatically on each run that overwrites or prunes files." 'DarkGray'
    exit 0
}

# --- List mode (the default) -------------------------------------------------
if (-not $restoring) {
    $newestRestorable = $dirs | Where-Object { Test-Path (Get-ManifestPath $_) } | Select-Object -First 1
    Write-Host "Backups in $backupsRoot (newest first):" -ForegroundColor Cyan
    Write-Host ""
    foreach ($d in $dirs) {
        $mp = Get-ManifestPath $d
        if (Test-Path $mp) {
            $note = ""
            $color = 'Green'
            try {
                $n = @((Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json).files).Count
                $text = "{0,2} file(s)" -f $n
            } catch {
                $text = "manifest.json does not parse"
                $color = 'Red'
            }
            if ($newestRestorable -and $d.Name -eq $newestRestorable.Name) { $note = "   <- -Latest" }
            Write-Host ("  {0}   {1}{2}" -f $d.Name, $text, $note) -ForegroundColor $color
        } else {
            Write-Host ("  {0}   no manifest -- not restorable by this script" -f $d.Name) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Preview:  restore.ps1 -Latest -DryRun   (or -Timestamp <stamp> -DryRun)" -ForegroundColor Cyan
    Write-Host "Restore:  restore.ps1 -Latest           (or -Timestamp <stamp>)" -ForegroundColor Cyan
    exit 0
}

# --- Pick the backup to restore ----------------------------------------------
$target = $null
if ($Timestamp) {
    $target = $dirs | Where-Object { $_.Name -eq $Timestamp } | Select-Object -First 1
    if (-not $target) {
        Fail @(
            "No backup named '$Timestamp' under .backups\.",
            "Available: $(@($dirs | ForEach-Object Name) -join ', ')"
        )
    }
} else {
    # -Latest means the newest backup that is actually restorable (has a manifest).
    $skippedNewer = @()
    foreach ($d in $dirs) {
        if (Test-Path (Get-ManifestPath $d)) { $target = $d; break }
        $skippedNewer += $d.Name
    }
    if (-not $target) {
        Fail @(
            "None of the $($dirs.Count) backup directories has a manifest.json, so none is restorable",
            "by this script. They predate manifests (deploy.ps1 has written one since 2026-07-25).",
            "The files are intact -- inspect and copy back by hand from: $backupsRoot"
        )
    }
    if ($skippedNewer.Count -gt 0) {
        Say "Note: skipped newer backup(s) without a manifest: $($skippedNewer -join ', ')" 'Yellow'
    }
}

# --- Read the manifest, refusing to guess when there is none -----------------
$manifestPath = Get-ManifestPath $target
if (-not (Test-Path $manifestPath)) {
    Fail @(
        ".backups\$($target.Name) has no manifest.json, so where its files belong was never recorded.",
        "Backups made before 2026-07-25 predate manifests; a directory holding only profile snapshots",
        "has none either. This script restores only what a manifest records rather than guessing.",
        "The files are intact -- inspect and copy back by hand:",
        "  $($target.FullName)"
    )
}

$manifest = $null
try { $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Fail ".backups\$($target.Name)\manifest.json does not parse: $($_.Exception.Message)" }

$entries = @($manifest.files)
if ($entries.Count -eq 0) {
    Say "manifest.json in .backups\$($target.Name) lists no files; nothing to restore." 'Yellow'
    exit 0
}

# --- Restore ------------------------------------------------------------------
Say "Restoring from .backups\$($target.Name)\ ($($entries.Count) file(s)):" 'Cyan' -Plan
Write-Host ""

$restored = 0
$same     = 0
$missing  = 0

foreach ($f in $entries) {
    $src = Join-Path $target.FullName $f.Label
    if (-not (Test-Path $src)) {
        Say "[MISS] $($f.Label) -- in the manifest but not in the backup directory" 'Yellow'
        $missing++
        continue
    }

    $content = [System.IO.File]::ReadAllText($src)
    $unchanged = (Test-Path $f.Dest) -and ([System.IO.File]::ReadAllText($f.Dest) -eq $content)

    if ($unchanged) {
        Say "[SAME] $($f.Label)" 'DarkGray'
        $same++
    } elseif ($DryRun) {
        Say "[OK]   $($f.Label) -> $($f.Dest)" 'Green' -Plan
        $restored++
    } else {
        Write-TextFile -Path $f.Dest -Content $content
        Say "[OK]   $($f.Label) -> $($f.Dest)" 'Green'
        $restored++
    }
}

# --- Files present in the backup but absent from its manifest ----------------
# Add-ClaudeProfileBlock snapshots whole profiles (profile-*.ps1) without manifest
# entries, because deploy only ever edits its managed block inside them. Surface
# them so nobody assumes a "restored" backup covered its every file.
$labels = @($entries | ForEach-Object { $_.Label })
$extras = @(Get-ChildItem $target.FullName -Recurse -File | ForEach-Object {
    $_.FullName.Substring($target.FullName.Length + 1)
} | Where-Object { $_ -ne 'manifest.json' -and $_ -notin $labels })

if ($extras.Count -gt 0) {
    Write-Host ""
    Say "Also in this backup, with no recorded destination (not restored):" 'Yellow'
    foreach ($x in $extras) { Say "  $x" 'Yellow' }
    Say "Typically whole-profile snapshots taken before a profile edit; copy back by hand if needed." 'DarkGray'
}

# --- Summary ------------------------------------------------------------------
Write-Host ""
Say "Restored $restored, already current $same, missing from backup $missing." 'Cyan' -Plan

if ($DryRun) {
    Write-Host "Dry run complete -- nothing was written. Re-run without -DryRun to apply." -ForegroundColor Yellow
} elseif ($restored -gt 0) {
    Write-Host "Restart Claude Code, and open a NEW terminal tab, for restored files to take effect." -ForegroundColor Cyan
    Write-Host "Verify with: powershell -ExecutionPolicy Bypass -File `"$repoRoot\doctor.ps1`"" -ForegroundColor Cyan
}
