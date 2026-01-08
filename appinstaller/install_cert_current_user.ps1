param(
  [string]$CertPath = (Join-Path $PSScriptRoot "neuravpn.cer")
)

if (-not (Test-Path -LiteralPath $CertPath)) {
  Write-Error "Certificate not found: $CertPath"
  exit 1
}

Write-Host "Importing certificate to CurrentUser stores..." -ForegroundColor Cyan
Import-Certificate -FilePath $CertPath -CertStoreLocation "Cert:\CurrentUser\TrustedPeople" | Out-Null
Import-Certificate -FilePath $CertPath -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null

Write-Host "OK. If installation still fails, install the certificate to LocalMachine (run install_cert.ps1 as Administrator)." -ForegroundColor Yellow

