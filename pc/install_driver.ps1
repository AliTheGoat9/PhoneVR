<#
.SYNOPSIS
  Registers the PhoneVR driver with SteamVR and opens the firewall for the phone's head-tracking packets.

.EXAMPLE
  .\install_driver.ps1                         # auto-detects SteamVR and the built driver
  .\install_driver.ps1 -WindowX 2560 -WindowY 0   # also move the SteamVR "display" window (virtual monitor to the right of a 2560 px wide main monitor)
  .\install_driver.ps1 -Remove                 # unregister
#>
param(
  [string]$DriverPath,
  [switch]$Remove,
  [int]$UdpPort = 5555,
  [int]$WindowX,
  [int]$WindowY,
  [int]$WindowWidth,
  [int]$WindowHeight,
  [double]$FovHDeg,
  [double]$DisplayHz
)

$ErrorActionPreference = 'Stop'

function Find-VrPathReg {
  $roots = @()
  $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
  if ($steam) {
    $steam = $steam -replace '/', '\'
    $roots += $steam
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
      Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object {
        $roots += ($_.Matches[0].Groups[1].Value -replace '\\\\', '\')
      }
    }
  }
  $roots += "${env:ProgramFiles(x86)}\Steam"
  foreach ($r in ($roots | Select-Object -Unique)) {
    $p = Join-Path $r 'steamapps\common\SteamVR\bin\win64\vrpathreg.exe'
    if (Test-Path $p) { return $p }
  }
  return $null
}

$vrpathreg = Find-VrPathReg
if (-not $vrpathreg) {
  throw "Could not find SteamVR (vrpathreg.exe). Install SteamVR from Steam, run it once, then try again."
}
Write-Host "SteamVR tools: $vrpathreg"

if (-not $DriverPath) {
  $candidates = @(
    (Join-Path $PSScriptRoot '..\driver\build\package\phonevr'),
    (Join-Path $PSScriptRoot '..\driver\build\Release\package\phonevr'),
    (Join-Path $PSScriptRoot 'phonevr')
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'bin\win64\driver_phonevr.dll')) { $DriverPath = (Resolve-Path $c).Path; break }
  }
}

if ($Remove) {
  if (-not $DriverPath) { throw "Pass -DriverPath <folder> so I know which registration to remove." }
  & $vrpathreg removedriver $DriverPath
  Get-NetFirewallRule -DisplayName 'PhoneVR head tracking*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  Write-Host "Removed."
  return
}

if (-not $DriverPath -or -not (Test-Path (Join-Path $DriverPath 'bin\win64\driver_phonevr.dll'))) {
  throw "driver_phonevr.dll not found. Build the driver first (see README, step 1) or pass -DriverPath <folder containing driver.vrdrivermanifest>."
}
$DriverPath = (Resolve-Path $DriverPath).Path

# Optional: patch the default settings that ship with the driver.
$settingsFile = Join-Path $DriverPath 'resources\settings\default.vrsettings'
$patch = @{}
if ($PSBoundParameters.ContainsKey('WindowX'))      { $patch['window_x'] = $WindowX }
if ($PSBoundParameters.ContainsKey('WindowY'))      { $patch['window_y'] = $WindowY }
if ($PSBoundParameters.ContainsKey('WindowWidth'))  { $patch['window_width'] = $WindowWidth }
if ($PSBoundParameters.ContainsKey('WindowHeight')) { $patch['window_height'] = $WindowHeight }
if ($PSBoundParameters.ContainsKey('FovHDeg'))      { $patch['fov_h_deg'] = $FovHDeg }
if ($PSBoundParameters.ContainsKey('DisplayHz'))    { $patch['display_hz'] = $DisplayHz }
if ($patch.Count -gt 0) {
  $json = Get-Content $settingsFile -Raw | ConvertFrom-Json
  foreach ($k in $patch.Keys) { $json.driver_phonevr.$k = $patch[$k] }
  $text = $json | ConvertTo-Json -Depth 6
  # SteamVR's parser dislikes a UTF-8 byte-order mark, so write without one.
  [System.IO.File]::WriteAllText($settingsFile, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host ("Updated settings: " + (($patch.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
}

& $vrpathreg adddriver $DriverPath
Write-Host ""
& $vrpathreg show

# Firewall rule (needs an elevated PowerShell; skipped otherwise).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
  Get-NetFirewallRule -DisplayName 'PhoneVR head tracking*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName "PhoneVR head tracking (UDP $UdpPort)" -Direction Inbound -Protocol UDP -LocalPort $UdpPort -Action Allow -Profile Private, Domain | Out-Null
  Write-Host "Firewall: allowed inbound UDP $UdpPort on Private/Domain networks."
  Write-Host "          (If your Wi-Fi is set to 'Public' in Windows, switch it to 'Private'.)"
} else {
  Write-Warning "Not running as administrator, so the firewall rule was not created. Re-run this script from an elevated PowerShell, or allow inbound UDP $UdpPort yourself."
}

Write-Host ""
Write-Host "Done. Start SteamVR; you should see a PhoneVR headset (it will show as not tracked until the phone connects)."
