<#
.SYNOPSIS
  Decrypt a secret previously stored by Set-Secret.ps1 and print it to stdout.

.DESCRIPTION
  Reads ~/.claude/.<Name>.enc and reverses the DPAPI SecureString scheme. Only succeeds
  for the same Windows user on the same machine that ran Set-Secret.ps1.

.PARAMETER Name
  Logical secret name, e.g. 'stripe-key', 'github-token', 'api-key'.

.EXAMPLE
  $env:GITHUB_TOKEN = (.\Get-Secret.ps1 -Name github-token)
.EXAMPLE
  .\Get-Secret.ps1 -Name stripe-key
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Name
)
$ErrorActionPreference = 'Stop'

$path = Join-Path $env:USERPROFILE ".claude\.$Name.enc"
if (-not (Test-Path $path)) { Write-Error "No encrypted secret at $path"; exit 1 }

try {
  $secure = Get-Content $path | ConvertTo-SecureString
} catch {
  Write-Error "Failed to decrypt $path (wrong Windows user or machine?): $_"; exit 2
}
[Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
)
