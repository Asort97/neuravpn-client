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

function Update-Pubspec([string]$buildName, [int]$buildNumber) {
  $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
  $content = [System.IO.File]::ReadAllText($pubspecPath)
  $content = $content -replace '(?m)^version:\s*\S+', "version: $buildName+$buildNumber"
  $content = $content -replace '(?m)^(\s+msix_version:\s*)\S+', "`${1}$buildName.0"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($pubspecPath, $content, $utf8NoBom)
  Write-Host "Updated pubspec.yaml: version=$buildName+$buildNumber, msix_version=$buildName.0" -ForegroundColor Green
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

function Build-Updater {
  $updaterDir = Join-Path $repoRoot "tool\updater"
  $outputExe = Join-Path $updaterDir "build\updater.exe"

  Write-Host "Building updater.exe..." -ForegroundColor Cyan
  Push-Location $updaterDir
  try {
    & dart pub get | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dart pub get failed for updater" }

    $buildDir = Join-Path $updaterDir "build"
    if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir | Out-Null }

    & dart compile exe bin/updater.dart -o $outputExe | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dart compile exe failed for updater" }

    Write-Host "Updater built: $outputExe" -ForegroundColor Green
  } finally {
    Pop-Location
  }
  return $outputExe
}

function Build-Windows([object]$config) {
  $flutterArgs = @(
    "build", "windows", "--release",
    "--build-name", "$($config.windows.buildName)",
    "--build-number", "$($config.windows.buildNumber)"
  )

  Push-Location $repoRoot
  try {
    Write-Host "Running flutter clean..." -ForegroundColor Cyan
    & flutter clean | Out-Host
    & flutter pub get | Out-Host
    & flutter @flutterArgs
    if ($LASTEXITCODE -ne 0) {
      throw "Windows build failed"
    }

    $buildOutput = Join-Path $repoRoot "build\windows\x64\runner\Release"

    # Build and copy updater.exe into the release folder
    $updaterExe = Build-Updater
    Copy-Item $updaterExe -Destination $buildOutput -Force
    Write-Host "Copied updater.exe to build output" -ForegroundColor Green

    # Create release zip (includes updater.exe)
    $zipName = "neuravpn-windows-v$($config.windows.buildName).zip"
    $zipPath = Join-Path $repoRoot "build\$zipName"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$buildOutput\*" -DestinationPath $zipPath -Force
    Write-Host "Created release zip: $zipPath" -ForegroundColor Green

    # Build Inno Setup installer. A release without a fresh installer is invalid.
    $iscc = Get-Command "iscc" -ErrorAction SilentlyContinue
    if (-not $iscc) {
      # Try standard Inno Setup install locations
      $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
      $isccPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $pf86 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
      )
      foreach ($p in $isccPaths) {
        if (Test-Path $p) { $iscc = $p; break }
      }
    } else {
      $iscc = $iscc.Source
    }

    if (-not $iscc) {
      throw "Inno Setup not found. Install it before building a Windows release."
    }

    $issPath = Join-Path (Join-Path $repoRoot 'installer') 'neuravpn.iss'
    $installerPath = Join-Path $repoRoot "build\neuravpn-setup-v$($config.windows.buildName).exe"
    if (Test-Path $installerPath) {
      Remove-Item $installerPath -Force
    }

    & $iscc "/DAppVersion=$($config.windows.buildName)" $issPath
    if ($LASTEXITCODE -ne 0) {
      throw "Inno Setup build failed"
    }
    if (-not (Test-Path $installerPath)) {
      throw "Inno Setup reported success but installer was not created: $installerPath"
    }
    Write-Host "Created installer: $installerPath" -ForegroundColor Green
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
    Update-Pubspec $BuildName $BuildNumber
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
