<#
.SYNOPSIS
  PhoneVR all-in-one launcher: checks the setup, starts SteamVR and streams the headset view to the phone.

.DESCRIPTION
  SteamVR draws the headset image into a window on a dedicated virtual display (2992x1344 @ 120 Hz, see
  VDD.Control.25.7.23). This script finds that display on whichever GPU it lives, captures only that display,
  and streams it to the phone. It refuses to stream a normal monitor, because that only mirrors your desktop.

.EXAMPLE
  .\phonevr_server.ps1
  .\phonevr_server.ps1 -BitrateMbps 80 -Fps 90
  .\phonevr_server.ps1 -PhoneIpOverride 192.168.42.129
#>

param(
  [int]$Port = 5000,
  [int]$Fps = 120,
  [double]$BitrateMbps = 100,
  [ValidateSet('auto', 'nvenc', 'amf', 'qsv')][string]$Encoder = 'auto',
  [int]$Gop = 60,
  [string]$PhoneIpOverride = ''
)

. (Join-Path $PSScriptRoot 'phonevr_common.ps1')

$Host.UI.RawUI.WindowTitle = "PhoneVR Server & Stream"
Clear-Host

function Fail([string]$msg) {
  if ($msg) { Write-Host $msg -ForegroundColor Red }
  Write-Host ""
  pause
  exit 1
}

Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "                    PHONEVR ALL-IN-ONE SERVER                      " -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. ffmpeg
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpegCmd) { Fail "[ERROR] ffmpeg not found on PATH. Install a full build (6.1 or newer) and add it to PATH." }
Write-Host "[OK] FFmpeg: $($ffmpegCmd.Source)" -ForegroundColor Green

# 2. SteamVR and the driver
$steamvrDir = Find-SteamVrDir
if (-not $steamvrDir) { Fail "[ERROR] SteamVR not found. Install it from Steam and run it once." }
$vrpathreg = Join-Path $steamvrDir 'bin\win64\vrpathreg.exe'
$repoDriver = (Resolve-Path (Join-Path $PSScriptRoot '..\driver\phonevr')).Path
$repoDll = Join-Path $repoDriver 'bin\win64\driver_phonevr.dll'

$registered = $null
foreach ($line in (& $vrpathreg show 2>&1)) {
  if ("$line" -match '^\s*phonevr\s*:\s*(.+?)\s*$') { $registered = $Matches[1] }
}
if (-not $registered) {
  Write-Host "[*] Registering the PhoneVR driver with SteamVR..." -ForegroundColor Yellow
  & $vrpathreg adddriver $repoDriver
  $registered = $repoDriver
}
Write-Host "[OK] PhoneVR driver: $registered" -ForegroundColor Green

# SteamVR loads the registered folder. If that is a copy (e.g. SteamVR\drivers\phonevr), keep it up to date.
$regDll = Join-Path $registered 'bin\win64\driver_phonevr.dll'
if ((Test-Path $repoDll) -and ((Resolve-Path $registered).Path -ne $repoDriver)) {
  $stale = -not (Test-Path $regDll) -or ((Get-FileHash $regDll).Hash -ne (Get-FileHash $repoDll).Hash)
  if ($stale) {
    Write-Host "[*] The installed driver copy is out of date; updating it from the project." -ForegroundColor Yellow
    if (Test-SteamVrRunning) {
      Write-Host "    SteamVR has the old driver loaded and must close first. Close SteamVR now? [Y/n] " -NoNewline -ForegroundColor Cyan
      if ((Read-Host) -match '^[Nn]') { Write-Host "    Skipped; SteamVR keeps using the old driver." -ForegroundColor Yellow }
      else { Stop-SteamVr }
    }
    if (-not (Test-SteamVrRunning)) {
      try {
        Copy-Item -Path (Join-Path $repoDriver '*') -Destination $registered -Recurse -Force -ErrorAction Stop
        Write-Host "[OK] Driver copy updated." -ForegroundColor Green
      } catch {
        Write-Host "[!] Could not update $registered ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host "    Run this window as administrator once, or re-register: pc\install_driver.ps1 -DriverPath driver\phonevr" -ForegroundColor Yellow
      }
    }
  }
}

# 3. The virtual display the headset image goes to
$settings = Get-Content (Join-Path $repoDriver 'resources\settings\default.vrsettings') -Raw | ConvertFrom-Json
$vrW = [int]$settings.driver_phonevr.window_width
$vrH = [int]$settings.driver_phonevr.window_height

Write-Host "[*] Looking for the ${vrW}x${vrH} virtual display on all GPUs..." -ForegroundColor Gray
$found = Find-VrCaptureOutput -Width $vrW -Height $vrH
if (-not $found.Match) {
  Write-NoVirtualDisplayHelp $found.All $vrW $vrH
  Fail ""
}
$capture = $found.Match
$enc = Resolve-Encoder $Encoder $capture
Write-Host ("[OK] Virtual display: GPU {0} ({1}), screen {2}, {3}x{4}. Encoder: {5}" -f `
  $capture.Adapter, $capture.Gpu, $capture.Output, $capture.Width, $capture.Height, $enc) -ForegroundColor Green

# 4. SteamVR. The driver picks the display when SteamVR starts, so a SteamVR that started before the virtual
#    display existed still has its headset window on the normal desktop.
if (Test-SteamVrRunning) {
  if ((Get-DriverDisplayStatus) -eq 'missing') {
    Write-Host "[!] SteamVR started before the virtual display was available, so the headset window is on your desktop." -ForegroundColor Yellow
    Write-Host "    Restart SteamVR now? [Y/n] " -NoNewline -ForegroundColor Cyan
    if ((Read-Host) -notmatch '^[Nn]') {
      Stop-SteamVr
      Start-Process "steam://rungameid/250820"
      Start-Sleep -Seconds 5
    }
  } else {
    Write-Host "[OK] SteamVR is running." -ForegroundColor Green
  }
} else {
  Write-Host "[*] Launching SteamVR..." -ForegroundColor Yellow
  Start-Process "steam://rungameid/250820"
  Start-Sleep -Seconds 5
}

# 5. Addresses for the phone app
Write-Host ""
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "               STEP 1: CONNECT YOUR PHONE IN THE APP                " -ForegroundColor Yellow
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  1. Open the PhoneVR app on your phone." -ForegroundColor White
Write-Host "  2. Enter one of these PC addresses:" -ForegroundColor White
Write-Host ""
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
  ForEach-Object { Write-Host "     -->  $($_.IPAddress)  <--  ($($_.InterfaceAlias))" -ForegroundColor Cyan }
Write-Host ""
Write-Host "  3. Tap START in the PhoneVR app." -ForegroundColor White
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

# 6. Stream
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " Streaming the virtual display at $Fps fps, $enc, $([int]$BitrateMbps) Mbps -> phone UDP $Port" -ForegroundColor Green
Write-Host " Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
Start-StreamLoop -Ffmpeg 'ffmpeg' -Capture $capture -Encoder $enc -Fps $Fps -BitrateMbps $BitrateMbps -Gop $Gop -Port $Port `
  -PhoneIpOverride $PhoneIpOverride
