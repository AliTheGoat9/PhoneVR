<#
.SYNOPSIS
  PhoneVR Master Server & Stream Launcher
  Prepares SteamVR, configures display coordinates, displays connection info, and starts NVENC video streaming to the phone.
#>

param(
  [int]$OutputIdx = -1,
  [int]$Port = 5000,
  [int]$Fps = 120,
  [double]$BitrateMbps = 100,
  [ValidateSet('nvenc', 'amf', 'qsv')][string]$Encoder = 'nvenc',
  [string]$PhoneIpOverride = ''
)

$Host.UI.RawUI.WindowTitle = "PhoneVR Server & Stream"
Clear-Host

Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "                    PHONEVR ALL-IN-ONE SERVER                      " -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check FFmpeg
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpegCmd) {
  Write-Host "[ERROR] ffmpeg not found on PATH!" -ForegroundColor Red
  Write-Host "Please install ffmpeg or add it to your system PATH." -ForegroundColor Yellow
  pause
  exit 1
}
Write-Host "[OK] FFmpeg detected: $($ffmpegCmd.Source)" -ForegroundColor Green

# 2. Check & Register SteamVR Driver
$steamvrPath = "C:\Program Files (x86)\Steam\steamapps\common\SteamVR"
$vrpathreg = Join-Path $steamvrPath "bin\win64\vrpathreg.exe"
$driverInstalledPath = Join-Path $steamvrPath "drivers\phonevr"
$driverLocalPath = Resolve-Path (Join-Path $PSScriptRoot "..\driver\phonevr") -ErrorAction SilentlyContinue

if (Test-Path $vrpathreg) {
  $regOutput = (& $vrpathreg show) 2>&1
  if ($regOutput -notmatch "phonevr") {
    Write-Host "[*] Registering PhoneVR driver with SteamVR..." -ForegroundColor Yellow
    $driverTarget = if (Test-Path $driverInstalledPath) { $driverInstalledPath } else { $driverLocalPath }
    & $vrpathreg adddriver $driverTarget
    Write-Host "[OK] PhoneVR driver registered." -ForegroundColor Green
  } else {
    Write-Host "[OK] PhoneVR driver is registered in SteamVR." -ForegroundColor Green
  }
}

# 3. Detect Displays
Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens

Write-Host ""
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " Available Displays for VR Capture:" -ForegroundColor Yellow
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray

for ($i = 0; $i -lt $screens.Count; $i++) {
  $s = $screens[$i]
  $tag = if ($s.Primary) { " [Primary Display]" } else { "" }
  Write-Host "  [$i] $($s.DeviceName) - $($s.Bounds.Width)x$($s.Bounds.Height) at ($($s.Bounds.X), $($s.Bounds.Y))$tag" -ForegroundColor White
}

# Select Display
$selectedIdx = $OutputIdx
if ($selectedIdx -lt 0 -or $selectedIdx -ge $screens.Count) {
  if ($screens.Count -eq 1) {
    $selectedIdx = 0
  } else {
    Write-Host ""
    $prompt = "Select display index to stream [0-$($screens.Count - 1)] (Default is 0): "
    Write-Host $prompt -NoNewline -ForegroundColor Cyan
    $choice = Read-Host
    if ([int]::TryParse($choice, [ref]$selectedIdx) -and $selectedIdx -ge 0 -and $selectedIdx -lt $screens.Count) {
      # Valid index selected
    } else {
      $selectedIdx = 0
    }
  }
}

$chosenScreen = $screens[$selectedIdx]
Write-Host ""
Write-Host "[OK] Selected Display $selectedIdx ($($chosenScreen.DeviceName)): $($chosenScreen.Bounds.Width)x$($chosenScreen.Bounds.Height) at ($($chosenScreen.Bounds.X), $($chosenScreen.Bounds.Y))" -ForegroundColor Green

# 4. Sync SteamVR Driver Window Settings to Match Selected Display
$settingsFiles = @(
  (Join-Path $driverInstalledPath "resources\settings\default.vrsettings"),
  (Join-Path $driverLocalPath "resources\settings\default.vrsettings")
)

foreach ($sf in $settingsFiles) {
  if (Test-Path $sf) {
    try {
      $json = Get-Content $sf -Raw | ConvertFrom-Json
      $json.driver_phonevr.window_x = [int]$chosenScreen.Bounds.X
      $json.driver_phonevr.window_y = [int]$chosenScreen.Bounds.Y
      $updated = $json | ConvertTo-Json -Depth 6
      [System.IO.File]::WriteAllText($sf, $updated, (New-Object System.Text.UTF8Encoding $false))
    } catch {}
  }
}
Write-Host "[OK] SteamVR window aligned to Display $selectedIdx coordinates: ($($chosenScreen.Bounds.X), $($chosenScreen.Bounds.Y))" -ForegroundColor Green

# 5. Launch SteamVR if not already running
$vrProc = Get-Process -Name "vrmonitor", "vrserver" -ErrorAction SilentlyContinue
if (-not $vrProc) {
  Write-Host "[*] Launching SteamVR..." -ForegroundColor Yellow
  Start-Process "steam://rungameid/250820"
  Write-Host "    Waiting for SteamVR to initialize..." -ForegroundColor Gray
  Start-Sleep -Seconds 5
} else {
  Write-Host "[OK] SteamVR is already running." -ForegroundColor Green
}

# 6. Show PC Local IP Addresses for Phone Connection
Write-Host ""
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "               STEP 1: CONNECT YOUR PHONE IN THE APP                " -ForegroundColor Yellow
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  1. Open the PhoneVR app on your phone." -ForegroundColor White
Write-Host "  2. In 'PC IP Address', enter one of these IPs:" -ForegroundColor White
Write-Host ""

$ipList = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
  $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' 
}
foreach ($ip in $ipList) {
  $ifName = $ip.InterfaceAlias
  Write-Host "     -->  $($ip.IPAddress)  <--  ($ifName)" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  3. Tap START in the PhoneVR app." -ForegroundColor White
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

# 7. Wait for Phone Connection
$ipFile = Join-Path $env:LOCALAPPDATA 'PhoneVR\phone_ip.txt'
function Get-PhoneIp {
  if ($PhoneIpOverride) { return $PhoneIpOverride }
  if (Test-Path $ipFile) {
    $content = (Get-Content $ipFile -Raw -ErrorAction SilentlyContinue)
    if ($content) { return $content.Trim() }
  }
  return $null
}

Write-Host "Waiting for phone connection on UDP 5555..." -ForegroundColor Yellow
$anim = @('|', '/', '-', '\')
$ai = 0
$targetIp = Get-PhoneIp

while (-not $targetIp) {
  $targetIp = Get-PhoneIp
  if ($targetIp) { break }
  Write-Host "`rWaiting for phone $($anim[$ai++ % 4])  " -NoNewline -ForegroundColor Yellow
  Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "[OK] Phone connected! IP Address: $targetIp" -ForegroundColor Green
Write-Host ""

# 8. Start ffmpeg Streaming
$bitrate = [int]$BitrateMbps
$bufKb = [int][math]::Ceiling($BitrateMbps * 1000 / $Fps * 3)
$Gop = 60

# ddagrab options
$grab = "ddagrab=output_idx=${selectedIdx}:framerate=${Fps}:draw_mouse=0"

switch ($Encoder) {
  'nvenc' {
    $enc = @(
      '-c:v', 'hevc_nvenc',
      '-preset', 'p3',
      '-tune', 'ull',
      '-rc', 'cbr',
      '-b:v', "${bitrate}M",
      '-maxrate', "${bitrate}M",
      '-bufsize', "${bufKb}k",
      '-g', $Gop,
      '-bf', 0,
      '-forced-idr', 1,
      '-zerolatency', 1,
      '-delay', 0,
      '-rc-lookahead', 0
    )
    $vf = @()
  }
  'amf' {
    $enc = @(
      '-c:v', 'hevc_amf',
      '-usage', 'ultralowlatency',
      '-quality', 'speed',
      '-rc', 'cbr',
      '-b:v', "${bitrate}M",
      '-maxrate', "${bitrate}M",
      '-bufsize', "${bufKb}k",
      '-g', $Gop,
      '-bf', 0
    )
    $vf = @()
  }
  'qsv' {
    $enc = @(
      '-c:v', 'hevc_qsv',
      '-preset', 'veryfast',
      '-low_power', 1,
      '-async_depth', 1,
      '-b:v', "${bitrate}M",
      '-maxrate', "${bitrate}M",
      '-g', $Gop,
      '-bf', 0
    )
    $vf = @('-vf', 'hwmap=derive_device=qsv,format=qsv')
  }
}

function Build-FfmpegArgs([string]$ip) {
  return @('-hide_banner', '-loglevel', 'warning', '-f', 'lavfi', '-i', $grab) + $vf + $enc +
         @('-fps_mode', 'passthrough', '-bsf:v', 'dump_extra=freq=keyframe', '-flush_packets', 1,
           '-f', 'rtp', '-payload_type', 96, "rtp://${ip}:${Port}?pkt_size=1200")
}

Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " Streaming: Display $selectedIdx at $Fps fps, $Encoder, $bitrate Mbps -> ${targetIp}:${Port}" -ForegroundColor Green
Write-Host " Press Ctrl+C at any time to stop streaming." -ForegroundColor Yellow
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
Write-Host ""

$proc = $null
try {
  while ($true) {
    $ip = Get-PhoneIp
    if (-not $ip) {
      Write-Host "Waiting for phone connection..." -ForegroundColor Yellow
      while (-not ($ip = Get-PhoneIp)) { Start-Sleep -Seconds 1 }
    }
    
    Write-Host "[*] Streaming to phone at $ip..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList (Build-FfmpegArgs $ip) -NoNewWindow -PassThru
    
    while (-not $proc.HasExited) {
      Start-Sleep -Milliseconds 1000
      if (-not $PhoneIpOverride) {
        $currentIp = Get-PhoneIp
        if ($currentIp -and $currentIp -ne $ip) {
          Write-Host "[!] Phone IP changed to $currentIp, restarting stream..." -ForegroundColor Yellow
          Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
          break
        }
      }
    }
    
    Write-Host "[*] Stream paused. Reconnecting when phone connects..." -ForegroundColor Gray
    Start-Sleep -Seconds 1
  }
} finally {
  if ($proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  }
}
