<#
  Shared helpers for phonevr_server.ps1, start_stream.ps1 and capture_test.ps1. Dot-source it:
      . (Join-Path $PSScriptRoot 'phonevr_common.ps1')
#>

$script:PhoneIpFile = Join-Path $env:LOCALAPPDATA 'PhoneVR\phone_ip.txt'

# ------------------------------------------------------------------------------------------------
# SteamVR
# ------------------------------------------------------------------------------------------------

# Steam library roots: the install folder from the registry plus every library in libraryfolders.vdf.
function Get-SteamRoots {
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
  return $roots | Select-Object -Unique
}

function Find-SteamVrDir {
  foreach ($r in Get-SteamRoots) {
    $p = Join-Path $r 'steamapps\common\SteamVR'
    if (Test-Path (Join-Path $p 'bin\win64\vrpathreg.exe')) { return $p }
  }
  return $null
}

function Find-VrPathReg {
  $d = Find-SteamVrDir
  if ($d) { return (Join-Path $d 'bin\win64\vrpathreg.exe') }
  return $null
}

function Test-SteamVrRunning {
  return [bool](Get-Process -Name 'vrserver', 'vrmonitor', 'vrcompositor' -ErrorAction SilentlyContinue)
}

function Stop-SteamVr {
  Get-Process -Name 'vrmonitor', 'vrserver', 'vrcompositor', 'vrdashboard', 'vrwebhelper' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 20 -and (Test-SteamVrRunning); $i++) { Start-Sleep -Milliseconds 500 }
}

# What the PhoneVR driver reported the last time SteamVR loaded it:
#   'placed'  - headset window is on the virtual display
#   'missing' - no matching display, the headset window sits on the normal desktop
#   $null     - unknown (old driver build or no log)
function Get-DriverDisplayStatus {
  $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
  if (-not $steam) { return $null }
  $log = Join-Path ($steam -replace '/', '\') 'logs\vrserver.txt'
  if (-not (Test-Path $log)) { return $null }
  $last = Select-String -Path $log -Pattern 'phonevr: (headset window placed on|WARNING: no \d+x\d+ monitor found)' -ErrorAction SilentlyContinue |
    Select-Object -Last 1
  if (-not $last) { return $null }
  if ($last.Line -match 'placed on') { return 'placed' }
  return 'missing'
}

# ------------------------------------------------------------------------------------------------
# Phone address
# ------------------------------------------------------------------------------------------------

# The driver rewrites phone_ip.txt about once a second while head-tracking packets arrive, so a file older than
# a few seconds is left over from an earlier session and must not be streamed to.
function Get-PhoneIp([string]$Override = '', [int]$MaxAgeSeconds = 5) {
  if ($Override) { return $Override }
  try {
    $f = Get-Item $script:PhoneIpFile -ErrorAction Stop
    if (((Get-Date) - $f.LastWriteTime).TotalSeconds -gt $MaxAgeSeconds) { return $null }
    $ip = (Get-Content $f.FullName -Raw -ErrorAction Stop).Trim()
    if ($ip) { return $ip }
  } catch {}
  return $null
}

# ------------------------------------------------------------------------------------------------
# Capture: find the virtual display
# ------------------------------------------------------------------------------------------------

function Invoke-FfmpegText([string]$Ffmpeg, [string]$ArgLine) {
  # cmd /c keeps Windows PowerShell 5.1 from turning ffmpeg's stderr into error records.
  return (& cmd.exe /c "`"$Ffmpeg`" $ArgLine 2>&1") -join "`n"
}

# Lists every screen ffmpeg's desktop duplication (ddagrab) can capture, on every GPU.
# Laptops with two GPUs have screens on both, and ddagrab without an explicit adapter only sees the first one.
function Get-CaptureOutputs([string]$Ffmpeg = 'ffmpeg') {
  $found = @()
  for ($a = 0; $a -lt 4; $a++) {
    $gpu = $null
    for ($o = 0; $o -lt 6; $o++) {
      $t = Invoke-FfmpegText $Ffmpeg "-hide_banner -init_hw_device d3d11va=dx:$a -filter_hw_device dx -filter_complex ddagrab=output_idx=${o}:framerate=5 -frames:v 1 -f null -"
      $dev = [regex]::Match($t, 'Using device ([0-9a-f]{4}):[0-9a-f]{4} \((.*)\)\.')
      if (-not $dev.Success) { break }   # no such adapter
      $gpu = $dev.Groups[2].Value
      $size = [regex]::Match($t, ', (\d{3,5})x(\d{3,5}) \[SAR')
      if (-not $size.Success) { break }  # no more outputs on this adapter
      $found += [pscustomobject]@{
        Adapter = $a
        Output  = $o
        Width   = [int]$size.Groups[1].Value
        Height  = [int]$size.Groups[2].Value
        Vendor  = $dev.Groups[1].Value
        Gpu     = $gpu
      }
    }
    if (-not $gpu) { break }             # adapter $a does not exist, so neither do later ones
  }
  return $found
}

function Find-VrCaptureOutput([int]$Width, [int]$Height, [string]$Ffmpeg = 'ffmpeg') {
  $all = @(Get-CaptureOutputs $Ffmpeg)
  $match = $all | Where-Object { $_.Width -eq $Width -and $_.Height -eq $Height } | Select-Object -First 1
  return [pscustomobject]@{ Match = $match; All = $all }
}

function Write-NoVirtualDisplayHelp($All, [int]$Width, [int]$Height) {
  Write-Host ""
  Write-Host "[ERROR] No ${Width}x${Height} display found, so there is nothing VR to stream." -ForegroundColor Red
  Write-Host "        Streaming a normal monitor is what makes the phone show a mirror of your desktop." -ForegroundColor Red
  Write-Host ""
  Write-Host "Screens ffmpeg can see:" -ForegroundColor Yellow
  foreach ($s in $All) { Write-Host ("  GPU {0} ({1}) screen {2}: {3}x{4}" -f $s.Adapter, $s.Gpu, $s.Output, $s.Width, $s.Height) }
  Write-Host ""
  Write-Host "Fix:" -ForegroundColor Yellow
  Write-Host "  1. Run VDD.Control.25.7.23\install_virtual_monitor.bat (it asks for admin rights)."
  Write-Host "  2. In Windows Settings > System > Display, set the new display to ${Width}x${Height} at 120 Hz"
  Write-Host "     and choose 'Extend these displays' (not 'Duplicate')."
  Write-Host "  3. Restart SteamVR, then run this again."
}

# ------------------------------------------------------------------------------------------------
# Encoding
# ------------------------------------------------------------------------------------------------

# 'auto' picks the encoder that belongs to the GPU the virtual display is on, so frames never cross GPUs.
function Resolve-Encoder([string]$Encoder, $Capture) {
  if ($Encoder -ne 'auto') { return $Encoder }
  switch ($Capture.Vendor) {
    '10de' { return 'nvenc' }
    '1002' { return 'amf' }
    '8086' { return 'qsv' }
    default { return 'nvenc' }
  }
}

function Get-FfmpegArgs {
  param(
    [string]$Ip, $Capture, [string]$Encoder, [int]$Fps, [double]$BitrateMbps, [int]$Gop, [int]$Port
  )
  $bitrate = [int]$BitrateMbps
  $bufKb = [int][math]::Ceiling($BitrateMbps * 1000 / $Fps * 3)   # about three frames of buffer keeps latency low
  $grab = "ddagrab=output_idx=$($Capture.Output):framerate=${Fps}:draw_mouse=0"

  switch ($Encoder) {
    'nvenc' {
      $enc = @('-c:v', 'hevc_nvenc', '-preset', 'p3', '-tune', 'ull', '-rc', 'cbr', '-b:v', "${bitrate}M", '-maxrate', "${bitrate}M",
               '-bufsize', "${bufKb}k", '-g', $Gop, '-bf', 0, '-forced-idr', 1, '-zerolatency', 1, '-delay', 0, '-rc-lookahead', 0)
    }
    'amf' {
      $enc = @('-c:v', 'hevc_amf', '-usage', 'ultralowlatency', '-quality', 'speed', '-rc', 'cbr', '-b:v', "${bitrate}M",
               '-maxrate', "${bitrate}M", '-bufsize', "${bufKb}k", '-g', $Gop, '-bf', 0)
    }
    'qsv' {
      $enc = @('-c:v', 'hevc_qsv', '-preset', 'veryfast', '-low_power', 1, '-async_depth', 1, '-b:v', "${bitrate}M",
               '-maxrate', "${bitrate}M", '-g', $Gop, '-bf', 0)
      $grab += ',hwmap=derive_device=qsv,format=qsv'
    }
  }

  return @('-hide_banner', '-loglevel', 'warning',
           '-init_hw_device', "d3d11va=dx:$($Capture.Adapter)", '-filter_hw_device', 'dx',
           '-filter_complex', $grab) + $enc +
         @('-fps_mode', 'passthrough', '-bsf:v', 'dump_extra=freq=keyframe', '-flush_packets', 1,
           '-f', 'rtp', '-payload_type', 96, "rtp://${Ip}:${Port}?pkt_size=1200")
}

# Runs ffmpeg towards the phone and restarts it when it exits or the phone's address changes. Never returns.
function Start-StreamLoop {
  param(
    [string]$Ffmpeg, $Capture, [string]$Encoder, [int]$Fps, [double]$BitrateMbps, [int]$Gop, [int]$Port,
    [string]$PhoneIpOverride = ''
  )
  $proc = $null
  try {
    while ($true) {
      $ip = Get-PhoneIp $PhoneIpOverride
      if (-not $ip) {
        Write-Host "Waiting for the phone (open the app and press START)..." -ForegroundColor Yellow
        while (-not ($ip = Get-PhoneIp $PhoneIpOverride)) { Start-Sleep -Milliseconds 500 }
      }
      Write-Host "[*] Streaming to phone at $ip" -ForegroundColor Cyan
      $args_ = Get-FfmpegArgs -Ip $ip -Capture $Capture -Encoder $Encoder -Fps $Fps -BitrateMbps $BitrateMbps -Gop $Gop -Port $Port
      $proc = Start-Process -FilePath $Ffmpeg -ArgumentList $args_ -NoNewWindow -PassThru
      while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 1000
        if (-not $PhoneIpOverride) {
          $now = Get-PhoneIp
          if ($now -and $now -ne $ip) {
            Write-Host "[!] Phone address changed to $now, restarting the stream." -ForegroundColor Yellow
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            break
          }
        }
      }
      Write-Host "[*] Stream stopped. Restarting when the phone is there..." -ForegroundColor Gray
      Start-Sleep -Seconds 1
    }
  } finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
  }
}
