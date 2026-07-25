<#
.SYNOPSIS
  Encrypt a secret to the per-user DPAPI store at ~/.claude/.<Name>.enc

.DESCRIPTION
  Uses the same scheme as the Anthropic key (.api-key.enc): a SecureString serialized
  with ConvertFrom-SecureString (no external key), which is Windows DPAPI bound to the
  CURRENT USER on the CURRENT MACHINE. The resulting hex blob cannot be decrypted by any
  other user, or on any other computer.

.PARAMETER Name
  Logical secret name. Produces ~/.claude/.<Name>.enc  (e.g. 'api-key', 'github-token').

.PARAMETER Value
  Optional. The secret value. OMIT THIS for interactive use -- you'll get a hidden secure
  prompt so the secret never lands in your shell history. Pass -Value only for automation.

.EXAMPLE
  .\Set-Secret.ps1 -Name api-key          # secure hidden prompt (recommended)
.EXAMPLE
  .\Set-Secret.ps1 -Name github-token
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Name,
  [string]$Value
)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$path = Join-Path $dir ".$Name.enc"

if ($PSBoundParameters.ContainsKey('Value') -and $Value) {
  $secure = ConvertTo-SecureString $Value -AsPlainText -Force
} else {
  $secure = Read-Host "Enter secret value for '$Name'" -AsSecureString
}
if ($null -eq $secure -or $secure.Length -eq 0) { Write-Error 'Empty secret; aborting.'; exit 1 }

# DPAPI (CurrentUser) -- identical scheme to .api-key.enc
$secure | ConvertFrom-SecureString | Set-Content -Path $path
Write-Host "Encrypted -> $path" -ForegroundColor Green
