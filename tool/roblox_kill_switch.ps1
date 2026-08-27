[CmdletBinding()]
param(
  [ValidateSet('Install', 'Refresh', 'Status', 'Uninstall')]
  [string]$Action = 'Install'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ruleGroup = 'NeuraVPN Roblox Kill Switch'
$taskName = 'NeuraVPN Roblox Kill Switch Refresh'
$installDirectory = Join-Path $env:ProgramData 'NeuraVPN'
$installedScript = Join-Path $installDirectory 'roblox_kill_switch.ps1'
$statePath = Join-Path $installDirectory 'roblox_kill_switch_state.json'

$dynamicKeywords = @(
  @{ Id = '{689ebc13-53ef-4de2-a237-c9659581e263}'; Keyword = 'roblox.com' },
  @{ Id = '{76b669b2-dbf6-4922-965b-5d339f0c760c}'; Keyword = '*.roblox.com' },
  @{ Id = '{19367188-37f0-4f86-920c-fcfd147d8bce}'; Keyword = 'rbxcdn.com' },
  @{ Id = '{8ed40dbc-1a9d-44bf-a548-206fa39c59bb}'; Keyword = '*.rbxcdn.com' },
  @{ Id = '{4051bce5-a5c2-4883-b986-2b7c777f47de}'; Keyword = 'rbx.com' },
  @{ Id = '{709d06ac-8184-4596-aa95-53b421710e93}'; Keyword = '*.rbx.com' },
  @{ Id = '{09494696-fdbb-412a-a6ac-839f30858ee8}'; Keyword = 'rbxinfra.com' },
  @{ Id = '{b88ec480-48a4-4476-a40d-11cf08378e20}'; Keyword = '*.rbxinfra.com' }
)

$robloxAddressRanges = @('128.116.0.0/16')
$blockedInterfaceTypes = @('Wired', 'Wireless')

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
  if (-not (Test-IsAdministrator)) {
    throw 'Administrator privileges are required for this action.'
  }
}

function Get-SavedState {
  if (-not (Test-Path -LiteralPath $statePath)) {
    return $null
  }

  return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}

function Save-InitialState {
  if (Test-Path -LiteralPath $statePath) {
    return
  }

  $profiles = @(
    Get-NetFirewallProfile | ForEach-Object {
      [pscustomobject]@{
        Name = $_.Name
        Enabled = [bool]$_.Enabled
      }
    }
  )

  $state = [pscustomobject]@{
    InstalledBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    LocalAppData = $env:LOCALAPPDATA
    OriginalFirewallProfiles = $profiles
  }

  $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Get-RobloxExecutables {
  $state = Get-SavedState
  $localAppData = if ($null -ne $state -and $state.LocalAppData) {
    [string]$state.LocalAppData
  } else {
    $env:LOCALAPPDATA
  }

  $roots = @(
    (Join-Path $localAppData 'Roblox'),
    (Join-Path $localAppData 'Bloxstrap'),
    (Join-Path $env:ProgramFiles 'Roblox')
  )

  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  if ($programFilesX86) {
    $roots += Join-Path $programFilesX86 'Roblox'
  }

  return @(
    $roots |
      Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
      ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue
      } |
      Select-Object -ExpandProperty FullName -Unique |
      Sort-Object
  )
}

function Remove-ManagedRules {
  Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function Ensure-DynamicKeywords {
  $availableIds = [System.Collections.Generic.List[string]]::new()

  foreach ($item in $dynamicKeywords) {
    try {
      $existing = Get-NetFirewallDynamicKeywordAddress -Id $item.Id -ErrorAction SilentlyContinue
      if ($null -ne $existing -and $existing.Keyword -ne $item.Keyword) {
        Remove-NetFirewallDynamicKeywordAddress -Id $item.Id -ErrorAction SilentlyContinue
        $existing = $null
      }

      if ($null -eq $existing) {
        $keywordParameters = @{
          Id = $item.Id
          Keyword = $item.Keyword
          AutoResolve = $true
        }
        New-NetFirewallDynamicKeywordAddress @keywordParameters | Out-Null
      }

      $availableIds.Add($item.Id)
    } catch {
      Write-Warning "Could not create FQDN rule for $($item.Keyword): $($_.Exception.Message)"
    }
  }

  return $availableIds.ToArray()
}

function Add-ManagedRules {
  param(
    [string[]]$DynamicKeywordIds,
    [string[]]$RobloxExecutables
  )

  foreach ($interfaceType in $blockedInterfaceTypes) {
    if ($DynamicKeywordIds.Count -gt 0) {
      $domainRuleParameters = @{
        DisplayName = "$ruleGroup - Domains - $interfaceType"
        Group = $ruleGroup
        Description = 'Blocks Roblox domains outside the NeuraVPN TUN interface.'
        Direction = 'Outbound'
        Action = 'Block'
        Enabled = 'True'
        Profile = 'Any'
        InterfaceType = $interfaceType
        RemoteDynamicKeywordAddresses = $DynamicKeywordIds
      }
      New-NetFirewallRule @domainRuleParameters | Out-Null
    }

    $networkRuleParameters = @{
      DisplayName = "$ruleGroup - Network - $interfaceType"
      Group = $ruleGroup
      Description = 'Blocks the Roblox network range outside the NeuraVPN TUN interface.'
      Direction = 'Outbound'
      Action = 'Block'
      Enabled = 'True'
      Profile = 'Any'
      InterfaceType = $interfaceType
      RemoteAddress = $robloxAddressRanges
    }
    New-NetFirewallRule @networkRuleParameters | Out-Null

    foreach ($programPath in $RobloxExecutables) {
      $programName = Split-Path -Leaf $programPath
      $versionDirectory = Split-Path -Leaf (Split-Path -Parent $programPath)
      $programRuleParameters = @{
        DisplayName = "$ruleGroup - $programName - $versionDirectory - $interfaceType"
        Group = $ruleGroup
        Description = 'Allows this Roblox executable to use NeuraVPN, but blocks direct wired and wireless Internet access.'
        Direction = 'Outbound'
        Action = 'Block'
        Enabled = 'True'
        Profile = 'Any'
        InterfaceType = $interfaceType
        Program = $programPath
      }
      New-NetFirewallRule @programRuleParameters | Out-Null
    }
  }
}

function Register-RefreshTask {
  $state = Get-SavedState
  if ($null -eq $state) {
    throw 'The installation state is missing.'
  }

  $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScript`" -Action Refresh"
  $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
  $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $state.InstalledBy
  $principalParameters = @{
    UserId = $state.InstalledBy
    LogonType = 'Interactive'
    RunLevel = 'Highest'
  }
  $taskPrincipal = New-ScheduledTaskPrincipal @principalParameters

  $taskParameters = @{
    TaskName = $taskName
    Description = 'Refreshes Roblox executable firewall rules after Roblox updates.'
    Action = $taskAction
    Trigger = $taskTrigger
    Principal = $taskPrincipal
    Force = $true
  }
  Register-ScheduledTask @taskParameters | Out-Null
}

function Install-KillSwitch {
  Assert-Administrator
  New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
  Save-InitialState

  if ($PSCommandPath -ne $installedScript) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
  }

  Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
  Refresh-KillSwitch
  Register-RefreshTask
}

function Refresh-KillSwitch {
  Assert-Administrator
  Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
  Remove-ManagedRules

  $keywordIds = @(Ensure-DynamicKeywords)
  $executables = @(Get-RobloxExecutables)
  Add-ManagedRules -DynamicKeywordIds $keywordIds -RobloxExecutables $executables
}

function Uninstall-KillSwitch {
  Assert-Administrator
  Remove-ManagedRules

  foreach ($item in $dynamicKeywords) {
    Remove-NetFirewallDynamicKeywordAddress -Id $item.Id -ErrorAction SilentlyContinue
  }

  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

  $state = Get-SavedState
  if ($null -ne $state) {
    foreach ($profile in @($state.OriginalFirewallProfiles)) {
      Set-NetFirewallProfile -Profile $profile.Name -Enabled ([bool]$profile.Enabled)
    }
  }

  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $installedScript -Force -ErrorAction SilentlyContinue
}

function Show-Status {
  $rules = @(Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue)
  $programFilters = @(
    $rules |
      Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
      Where-Object { $_.Program -and $_.Program -ne 'Any' } |
      Select-Object -ExpandProperty Program -Unique
  )
  $profiles = @(
    Get-NetFirewallProfile | Select-Object Name, Enabled
  )

  [pscustomobject]@{
    Installed = ($rules.Count -gt 0)
    FirewallRules = $rules.Count
    ProtectedExecutables = $programFilters.Count
    RefreshTaskInstalled = [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    FirewallProfiles = $profiles
    Programs = $programFilters
  } | ConvertTo-Json -Depth 5
}

switch ($Action) {
  'Install' {
    Install-KillSwitch
    Show-Status
  }
  'Refresh' {
    Refresh-KillSwitch
    Show-Status
  }
  'Status' {
    Show-Status
  }
  'Uninstall' {
    Uninstall-KillSwitch
    Show-Status
  }
}
