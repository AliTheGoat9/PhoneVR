<#
.SYNOPSIS
  Captures the SteamVR "display" window and streams it to the phone as low-latency H.265 over RTP/UDP.

.DESCRIPTION
  Needs ffmpeg 6.1 or newer (a "full" Windows build) on PATH or passed with -FfmpegPath.
  The phone's address is taken from what the SteamVR driver recorded when the phone connected; pass -PhoneIp to override.

.EXAMPLE
  .\start_stream.ps1 -ListDisplays
  .\start_stream.ps1 -OutputIdx 1 -TestCapture      # saves one frame so you can check you picked the right monitor
  .\start_stream.ps1 -OutputIdx 1                   # stream (NVIDIA)
  .\start_stream.ps1 -OutputIdx 1 -Encoder amf -BitrateMbps 80
  .\start_stream.ps1 -OutputIdx 1 -Fps 90 -BitrateMbps 70   # if the phone's decoder can't keep up with 120
#>
param(
  [string]$PhoneIp,
  [int]$Port = 5000,
  [int]$Fps = 120,
  [int]$Width = 2992,
  [int]$Height = 1344,
  [int]$OffsetX = 0,
  [int]$OffsetY = 0,
  [int]$OutputIdx = 0,
  [double]$BitrateMbps = 100,
  [ValidateSet('nvenc', 'amf', 'qsv')][string]$Encoder = 'nvenc',
  [int]$Gop = 60,
  [string]$FfmpegPath = 'ffmpeg',
  [switch]$ListDisplays,
  [switch]$TestCapture,
  [switch]$PrintOnly
)

$ErrorActionPreference = 'Stop'
$ipFile = Join-Path $env:LOCALAPPDATA 'PhoneVR\phone_ip.txt'

if ($ListDisplays) {
  Add-Type -AssemblyName System.Windows.Forms
  $i = 0
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    "{0}: {1}  {2}x{3} at ({4},{5}){6}" -f $i, $s.DeviceName, $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $(if ($s.Primary) { '  [primary]' } else { '' })
    $i++
  }
  ""
  "The number is a guess at ffmpeg's -OutputIdx; confirm with -TestCapture (it usually matches)."
  "Your local IPv4 address(es), to type into the phone app:"
  Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { "  " + $_.IPAddress + "  (" + $_.InterfaceAlias + ")" }
  return
}

if (-not (Get-Command $FfmpegPath -ErrorAction SilentlyContinue)) {
  throw "ffmpeg not found. Download a full build (6.1 or newer) from https://www.gyan.dev/ffmpeg/builds/ or https://github.com/BtbN/FFmpeg-Builds/releases, then put it on PATH or use -FfmpegPath."
}

$grab = "ddagrab=output_idx=${OutputIdx}:framerate=${Fps}:video_size=${Width}x${Height}:offset_x=${OffsetX}:offset_y=${OffsetY}:draw_mouse=0"

if ($TestCapture) {
  $png = Join-Path (Get-Location) 'phonevr_capture_test.png'
  & $FfmpegPath -hide_banner -loglevel warning -y -f lavfi -i "ddagrab=output_idx=${OutputIdx}:framerate=5:video_size=${Width}x${Height}:offset_x=${OffsetX}:offset_y=${OffsetY}:draw_mouse=0,hwdownload,format=bgra" -frames:v 1 $png
  if (Test-Path $png) { Write-Host "Saved $png - it should show the SteamVR window / virtual monitor."; Start-Process $png }
  else { Write-Warning "Capture failed. Try another -OutputIdx (see -ListDisplays)." }
  return
}

$bitrate = [int]$BitrateMbps
$bufKb = [int][math]::Ceiling($BitrateMbps * 1000 / $Fps * 3)   # about three frames of VBV buffer keeps latency low

switch ($Encoder) {
  'nvenc' {
    $enc = @('-c:v', 'hevc_nvenc', '-preset', 'p3', '-tune', 'ull', '-rc', 'cbr', '-b:v', "${bitrate}M", '-maxrate', "${bitrate}M", '-bufsize', "${bufKb}k",
             '-g', $Gop, '-bf', 0, '-forced-idr', 1, '-zerolatency', 1, '-delay', 0, '-rc-lookahead', 0)
    $vf = @()
  }
  'amf' {
    $enc = @('-c:v', 'hevc_amf', '-usage', 'ultralowlatency', '-quality', 'speed', '-rc', 'cbr', '-b:v', "${bitrate}M", '-maxrate', "${bitrate}M", '-bufsize', "${bufKb}k",
             '-g', $Gop, '-bf', 0)
    $vf = @()
  }
  'qsv' {
    $enc = @('-c:v', 'hevc_qsv', '-preset', 'veryfast', '-low_power', 1, '-async_depth', 1, '-b:v', "${bitrate}M", '-maxrate', "${bitrate}M",
             '-g', $Gop, '-bf', 0)
    $vf = @('-vf', 'hwmap=derive_device=qsv,format=qsv')
  }
}

function Get-Args([string]$ip) {
  $a = @('-hide_banner', '-loglevel', 'warning', '-f', 'lavfi', '-i', $grab) + $vf + $enc +
       @('-fps_mode', 'passthrough', '-bsf:v', 'dump_extra=freq=keyframe', '-flush_packets', 1,
         '-f', 'rtp', '-payload_type', 96, "rtp://${ip}:${Port}?pkt_size=1200")
  return $a
}

function Read-PhoneIp {
  if ($PhoneIp) { return $PhoneIp }
  if (Test-Path $ipFile) { return (Get-Content $ipFile -Raw).Trim() }
  return $null
}

if ($PrintOnly) {
  "$FfmpegPath " + ((Get-Args '<phone-ip>') -join ' ')
  return
}

Write-Host "PhoneVR stream: ${Width}x${Height} @ ${Fps} fps, $Encoder, ${bitrate} Mbps -> UDP port $Port. Ctrl+C to stop."
$proc = $null
try {
  while ($true) {
    $ip = Read-PhoneIp
    if (-not $ip) {
      Write-Host "Waiting for the phone to connect to SteamVR (open the app on the phone and press Start)..."
      while (-not ($ip = Read-PhoneIp)) { Start-Sleep -Seconds 1 }
    }
    Write-Host "Streaming to $ip"
    $proc = Start-Process -FilePath $FfmpegPath -ArgumentList (Get-Args $ip) -NoNewWindow -PassThru
    # Restart if ffmpeg exits (it does when the phone app closes and the port becomes unreachable)
    # or if the phone's address changes.
    while (-not $proc.HasExited) {
      Start-Sleep -Milliseconds 1000
      if (-not $PhoneIp) {
        $now = Read-PhoneIp
        if ($now -and $now -ne $ip) {
          Write-Host "Phone address changed to $now, restarting."
          Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
          break
        }
      }
    }
    Start-Sleep -Seconds 1
  }
}
finally {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}
