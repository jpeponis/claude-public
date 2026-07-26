# lib/Common.ps1 -- Shared helpers, dot-sourced by collect.ps1, deploy.ps1, doctor.ps1,
# restore.ps1, publish.ps1 and apply-terminal-keybinding.ps1.
#
# Dot-source with:  . (Join-Path $repoRoot "lib\Common.ps1")
#
# Everything here is repo-native (never deployed to ~/.claude).

# --- UTF-8 without BOM: the encoding every file in this repo is written with ---
function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

# --- Desktop, resolved the same way Documents is -----------------------------
# "$env:USERPROFILE\Desktop" is wrong on any machine with OneDrive Known Folder Move
# enabled, which is the Windows 11 default on a consumer setup: the real Desktop is
# then "$env:USERPROFILE\OneDrive\Desktop" and the literal path either does not exist
# or is a stale leftover. deploy.ps1 puts CLAUDE.md and .claude\settings.local.json
# there, so getting this wrong writes project config to a directory the user never
# opens -- the same silent-success failure the profile paths had.
#
# bootstrap.ps1 deliberately repeats this logic inline rather than calling it: it runs
# before the repo exists, so it cannot dot-source this file.
function Get-DesktopPath {
    $d = [Environment]::GetFolderPath('Desktop')
    if ($d) { return $d }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

# --- What this repo syncs: ONE description, three consumers ------------------
# collect.ps1 (local -> repo), deploy.ps1 (repo -> local) and doctor.ps1 (is it
# actually there?) all need the same list. It used to be written out three times.
# Two copies drifting is a bug you notice; the third was doctor's, and a mapping
# missing from THAT one is invisible -- doctor simply stops checking a file and
# keeps printing green. So the list lives here, and adding a mapping teaches all
# three scripts at once.
#
# Deliberately NOT in this plan, each for a reason worth keeping:
#   - The PowerShell profile. Collecting a whole profile drags in unrelated shell
#     config and can only ever capture one of the two profile paths (5.1 vs 7+).
#     The functions live in claude-functions.ps1; profiles get a managed block
#     that dot-sources it (see Add-ClaudeProfileBlock).
#   - ~/.claude/.*.enc secrets. DPAPI-bound to one user on one machine, so they
#     cannot travel. secrets.json registers the names; each machine runs Set-Secret.ps1.
#   - Repo-native scripts ("System Prompt.txt", lib\, and the launcher / doctor /
#     restore / publish scripts). They are run FROM the repo, not deployed.
function Get-SyncPlan {
    param(
        [Parameter(Mandatory)][string]$ClaudeHome,
        [Parameter(Mandatory)][string]$DesktopDir
    )
    @{
        # Repo path (relative to repo root) <-> absolute local path.
        Files = @(
            @{ Repo = 'global\settings.json';                        Local = "$ClaudeHome\settings.json" }
            @{ Repo = 'global\statusline-command.ps1';               Local = "$ClaudeHome\statusline-command.ps1" }
            @{ Repo = 'powershell\claude-functions.ps1';             Local = "$ClaudeHome\claude-functions.ps1" }
            @{ Repo = 'project-desktop\CLAUDE.md';                   Local = "$DesktopDir\CLAUDE.md" }
            @{ Repo = 'project-desktop\.claude\settings.local.json'; Local = "$DesktopDir\.claude\settings.local.json" }
        )
        # Every file matching Filter is synced as a unit, in both directions:
        # deleting one locally removes it from the repo on the next collect, and
        # deleting it from the repo prunes it locally on the next deploy.
        Dirs = @(
            @{ Name = 'commands';  Repo = 'global\commands'; Local = "$ClaudeHome\commands"; Filter = '*.md' }
            @{ Name = 'agents';    Repo = 'global\agents';   Local = "$ClaudeHome\agents";   Filter = '*.md' }
            @{ Name = 'workflows'; Repo = 'project-desktop\.claude\workflows'; Local = "$DesktopDir\.claude\workflows"; Filter = '*.js' }
        )
    }
}

# The repo stores the username as {{USERNAME}} so one repo serves every machine.
# String.Replace, not -replace: the token's casing is fixed, and a regex
# replacement would give special meaning to '$' in the username.
function Expand-UserName {
    param([string]$Text, [string]$UserName)
    return $Text.Replace('{{USERNAME}}', $UserName)
}

# --- secrets.json, read the same way by deploy.ps1 and doctor.ps1 ------------
# Returns the registry entries, or $null when the file is absent. Invalid JSON
# THROWS rather than returning empty: silently checking zero secrets is how a
# store that nothing can read still reports as fine.
function Get-SecretsRegistry {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Join-Path $RepoRoot 'secrets.json'
    if (-not (Test-Path $path)) { return $null }
    return @((Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json).secrets)
}

# --- .backups\ --------------------------------------------------------------
# deploy.ps1 names its backup directories with a sortable timestamp. Anything
# else under .backups\ belongs to something else -- apply-terminal-keybinding.ps1
# keeps its own snapshots in .backups\terminal\ -- and must not be mistaken for a
# deploy backup. Name-sorting alone does not separate them: 'terminal' sorts
# ABOVE every digit, so restore.ps1 -Latest used to announce it as a newer backup
# it was skipping, on every single run.
# Newest first; the stamp format sorts chronologically as text.
function Get-BackupDirs {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root = Join-Path $RepoRoot '.backups'
    if (-not (Test-Path $root)) { return @() }
    return @(Get-ChildItem $root -Directory |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}$' } |
        Sort-Object Name -Descending)
}

# --- PowerShell profile discovery -------------------------------------------
# Windows PowerShell 5.1 reads Documents\WindowsPowerShell\, PowerShell 7+ reads
# Documents\PowerShell\. Both must be wired up or the claude-* functions exist in
# only one of the user's shells (this was a real, months-long silent failure).
#
# Documents is resolved via GetFolderPath('MyDocuments'), NOT "$env:USERPROFILE\Documents":
# OneDrive Known Folder Move redirects Documents, and hardcoding the literal path
# installs into a directory the user's shells never read.
function Get-ProfilePaths {
    $paths = @()

    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ($docs) {
        $paths += Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'  # 5.1
        $paths += Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'         # 7+
    }

    # Ask pwsh itself, in case it reports somewhere the two paths above miss.
    #
    # The '2>$null' is why the preference is relaxed here. Redirecting a native command's
    # stderr makes each line a PowerShell error record, and this file is dot-sourced into
    # deploy/collect/restore/publish/sync-config, all of which set
    # $ErrorActionPreference = 'Stop' -- which makes that record terminating. The catch
    # below would then swallow it and quietly drop this path, so any startup message from
    # pwsh (a profile warning, a preview-version notice) would cost us the very path this
    # block exists to find, with nothing reported. Same shape as the Test-JsonValid bug:
    # a catch hiding a failure rather than handling one.
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $p = & $pwsh.Source -NoProfile -NonInteractive -Command '$PROFILE.CurrentUserCurrentHost' 2>$null
            if ($p) { $paths += ([string]$p).Trim() }
        } catch {
            # pwsh present but unusable -- the two literal paths above still stand.
        } finally {
            $ErrorActionPreference = $previousEap
        }
    }

    # And the shell running this script.
    if ($PROFILE) { $paths += [string]$PROFILE }

    $paths | Where-Object { $_ } | Select-Object -Unique
}

# --- Managed block injected into each profile -------------------------------
# The functions live in one synced file; each profile only gets a dot-source line.
# That keeps the install additive: a user's existing profile is never rewritten.
#
# Detection deliberately matches only the stable prefix, not the whole start line.
# The trailing text has already changed once (an em-dash became '--' when these scripts
# were made pure ASCII), and blocks written by the older version are still out there in
# real profiles. Matching the prefix means an existing block is recognised and REPLACED
# rather than missed and duplicated.
function Get-ClaudeBlockMarkers {
    @{
        Start         = '# --- Claude Code config (managed block) -- do not edit inside ---'
        End           = '# --- end Claude Code config ---'
        DetectPattern = [regex]::Escape('# --- Claude Code config (managed block)')
    }
}

function Get-ClaudeProfileBlock {
    $m = Get-ClaudeBlockMarkers
    @"
$($m.Start)
`$claudeFunctions = "`$env:USERPROFILE\.claude\claude-functions.ps1"
if (Test-Path `$claudeFunctions) { . `$claudeFunctions }
$($m.End)
"@
}

function Test-ClaudeProfileBlock {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $m = Get-ClaudeBlockMarkers
    return (Get-Content $Path -Raw -Encoding UTF8) -match $m.DetectPattern
}

# Idempotent: appends the block if absent, replaces it in place if present but stale,
# leaves everything outside the markers untouched. Returns one of
# 'added' | 'updated' | 'unchanged' | 'would-add' | 'would-update'.
function Add-ClaudeProfileBlock {
    param(
        [string]$Path,
        [switch]$DryRun,
        [string]$BackupDir
    )

    $m     = Get-ClaudeBlockMarkers
    $block = Get-ClaudeProfileBlock
    $existing = if (Test-Path $Path) { Get-Content $Path -Raw -Encoding UTF8 } else { '' }

    $rx = [regex]("(?s)" + $m.DetectPattern + ".*?" + [regex]::Escape($m.End))
    $hasBlock = $rx.IsMatch($existing)

    if ($hasBlock) {
        $updated = $rx.Replace($existing, $block, 1)
        if ($updated -eq $existing) { return 'unchanged' }
        if ($DryRun) { return 'would-update' }
        $action = 'updated'
    } else {
        $sep = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }
        $updated = $existing.TrimEnd() + $sep + $block + "`r`n"
        if ($DryRun) { return 'would-add' }
        $action = 'added'
    }

    if ($BackupDir -and (Test-Path $Path)) {
        $leaf = Split-Path -Leaf (Split-Path -Parent $Path)   # WindowsPowerShell | PowerShell
        $dest = Join-Path $BackupDir "profile-$leaf.ps1"
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item $Path $dest -Force
    }

    Write-TextFile -Path $Path -Content $updated
    return $action
}

# --- Windows Terminal ------------------------------------------------------
# settings.json lives under a package path that differs across installs
# (stable / Preview / unpackaged), so probe all of them.
function Get-TerminalSettingsPaths {
    $paths = @()
    $pkgRoot = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path $pkgRoot) {
        Get-ChildItem $pkgRoot -Directory -Filter "Microsoft.WindowsTerminal*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $p = Join-Path $_.FullName "LocalState\settings.json"
                if (Test-Path $p) { $paths += $p }
            }
    }
    $unpackaged = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json"
    if (Test-Path $unpackaged) { $paths += $unpackaged }
    $paths | Select-Object -Unique
}

# Validate JSON, tolerating comments and trailing commas the way Windows Terminal does.
#
# System.Text.Json is the clean way to do this, but it does NOT exist on Windows
# PowerShell 5.1 (.NET Framework 4.x ships it only as an optional NuGet package).
# Without the type check below, the type lookup threw, the catch swallowed it, and this
# returned $false for EVERY input under 5.1 -- which made doctor.ps1 report perfectly
# good settings files as corrupt, and made apply-terminal-keybinding.ps1 refuse to add
# the Shift+Enter binding while blaming "unexpected structure".
function Test-JsonValid {
    param([string]$Json)

    if ('System.Text.Json.JsonDocument' -as [type]) {
        try {
            $opts = [System.Text.Json.JsonDocumentOptions]::new()
            $opts.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
            $opts.AllowTrailingCommas = $true
            [void][System.Text.Json.JsonDocument]::Parse($Json, $opts)
            return $true
        } catch {
            return $false
        }
    }

    # 5.1 fallback: ConvertFrom-Json rejects comments and trailing commas, so strip both
    # first. The comment pattern is anchored to the start of a line, so a "//" inside a
    # string (a URL, say) is left alone.
    try {
        $stripped = [regex]::Replace($Json,     '(?m)^\s*//.*$', '')
        $stripped = [regex]::Replace($stripped, ',(\s*[}\]])',   '$1')
        [void]($stripped | ConvertFrom-Json)
        return $true
    } catch {
        return $false
    }
}

# Returns @{ Path; DefaultProfileName; DefaultProfileGuid } for the first readable
# Terminal settings.json, or $null. Used by doctor.ps1 to answer the question that
# actually matters: does the shell the user's Terminal opens by default get the
# claude-* functions?
function Get-TerminalDefaultProfile {
    foreach ($path in @(Get-TerminalSettingsPaths)) {
        try {
            $raw = (Get-Content $path -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
            $j = $raw | ConvertFrom-Json
            $guid = $j.defaultProfile
            $name = ($j.profiles.list | Where-Object { $_.guid -eq $guid } | Select-Object -First 1).name
            return @{ Path = $path; DefaultProfileName = $name; DefaultProfileGuid = $guid }
        } catch { continue }
    }
    return $null
}
