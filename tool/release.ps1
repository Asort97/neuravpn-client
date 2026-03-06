param(
  [ValidateSet("show", "set", "build")]
  [string]$Action = "show",

  [ValidateSet("android", "windows")]
  [string]$Platform,

  [string]$BuildName,
  [int]$BuildNumber,
  [switch]$SplitPerAbi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath = Join-Path $PSScriptRoot "release_versions.json"

function Load-Config {
  if (-not (Test-Path $configPath)) {
    throw "Config not found: $configPath"
  }
  return Get-Content $configPath -Raw | ConvertFrom-Json
}

function Save-Config([object]$config) {
  $json = $config | ConvertTo-Json -Depth 6
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($configPath, $json, $utf8NoBom)
}

function Assert-PlatformAndVersion {
  if ([string]::IsNullOrWhiteSpace($Platform)) {
    throw "Platform is required. Use -Platform android|windows"
  }
  if ([string]::IsNullOrWhiteSpace($BuildName)) {
    throw "BuildName is required. Example: -BuildName 1.5.0"
  }
  if ($BuildNumber -le 0) {
    throw "BuildNumber must be > 0. Example: -BuildNumber 1500"
  }
}

function Show-Config([object]$config) {
  Write-Host "Current release versions:" -ForegroundColor Cyan
  Write-Host "  Android: buildName=$($config.android.buildName), buildNumber=$($config.android.buildNumber)"
  Write-Host "  Windows: buildName=$($config.windows.buildName), buildNumber=$($config.windows.buildNumber)"
}

function Build-Android([object]$config) {
  $args = @(
    "build", "apk", "--release",
    "--build-name", "$($config.android.buildName)",
    "--build-number", "$($config.android.buildNumber)"
  )
  if ($SplitPerAbi) {
    $args += "--split-per-abi"
  }

  Push-Location $repoRoot
  try {
    & flutter @args
    if ($LASTEXITCODE -ne 0) {
      throw "Android build failed"
    }
  } finally {
    Pop-Location
  }
}

function Build-Windows([object]$config) {
  $args = @(
    "build", "windows", "--release",
    "--build-name", "$($config.windows.buildName)",
    "--build-number", "$($config.windows.buildNumber)"
  )

  Push-Location $repoRoot
  try {
    & flutter @args
    if ($LASTEXITCODE -ne 0) {
      throw "Windows build failed"
    }
  } finally {
    Pop-Location
  }
}

$config = Load-Config

switch ($Action) {
  "show" {
    Show-Config $config
    break
  }
  "set" {
    Assert-PlatformAndVersion
    $config.$Platform.buildName = $BuildName
    $config.$Platform.buildNumber = $BuildNumber
    Save-Config $config
    Show-Config $config
    break
  }
  "build" {
    if ([string]::IsNullOrWhiteSpace($Platform)) {
      throw "Platform is required for build. Use -Platform android|windows"
    }
    Show-Config $config
    if ($Platform -eq "android") {
      Build-Android $config
    } else {
      Build-Windows $config
    }
    break
  }
}
