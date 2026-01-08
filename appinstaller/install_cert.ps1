param(
  [string]$CertPath = (Join-Path $PSScriptRoot "neuravpn.cer")
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error "Run this script in an Administrator PowerShell (Right click → Run as administrator)."
  exit 1
}

if (-not (Test-Path -LiteralPath $CertPath)) {
  Write-Error "Certificate not found: $CertPath"
  exit 1
}

Write-Host "Importing certificate to LocalMachine stores..." -ForegroundColor Cyan
Import-Certificate -FilePath $CertPath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
Import-Certificate -FilePath $CertPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null

Write-Host "OK. You can now install neuravpn via the .appinstaller file." -ForegroundColor Green

