<#
.SYNOPSIS
  Decrypt a secret previously stored by Set-Secret.ps1 and print it to stdout.

.DESCRIPTION
  Reads ~/.claude/.<Name>.enc and reverses the DPAPI SecureString scheme. Only succeeds
  for the same Windows user on the same machine that ran Set-Secret.ps1.

.PARAMETER Name
  Logical secret name, e.g. 'openrouter-key', 'github-token'.

.EXAMPLE
  $env:GITHUB_TOKEN = (.\Get-Secret.ps1 -Name github-token)
.EXAMPLE
  .\Get-Secret.ps1 -Name openrouter-key

.NOTES
  Exit codes: 0 = printed, 1 = no store file, 2 = store present but empty or not
  decryptable. On failure nothing goes to stdout and one line goes to stderr, so an
  in-process caller (& .\Get-Secret.ps1) sees an empty result plus $LASTEXITCODE rather
  than an exception. That stderr line is written to the console directly and is not
  silenced by 2>$null.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Name
)
$ErrorActionPreference = 'Stop'

# [Console]::Error, not Write-Error: under 'Stop' Write-Error throws before the exit
# that follows it runs, so every failure used to surface as exit 1 and an exception.
function Fail([int]$Code, [string]$Message) {
  [Console]::Error.WriteLine("Get-Secret: $Message")
  exit $Code
}

$path = Join-Path $env:USERPROFILE ".claude\.$Name.enc"
if (-not (Test-Path -LiteralPath $path)) { Fail 1 "No encrypted secret at $path" }

$cipher = "$(Get-Content -LiteralPath $path -Raw)".Trim()
if (-not $cipher) { Fail 2 "$path is empty; re-create it with Set-Secret.ps1 -Name $Name" }
try {
  $secure = ConvertTo-SecureString $cipher
} catch {
  Fail 2 "Failed to decrypt $path (wrong Windows user or machine?): $($_.Exception.Message.Trim())"
}
[Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
)
exit 0
