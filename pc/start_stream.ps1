<#
.SYNOPSIS
  Streams the PhoneVR virtual display to the phone as low-latency H.265 over RTP/UDP (no SteamVR checks).
  phonevr_server.ps1 does the same plus setup; use this one when SteamVR is already running.

.DESCRIPTION
  Needs ffmpeg 6.1 or newer (a "full" Windows build) on PATH or passed with -FfmpegPath.
  The virtual display is found automatically on any GPU by its resolution (-Width x -Height). Pass -Adapter and
  -OutputIdx to pick a screen yourself (see -ListDisplays).
  The phone's address comes from the SteamVR driver while the phone is connected; pass -PhoneIp to override.

.EXAMPLE
  .\start_stream.ps1 -ListDisplays
  .\start_stream.ps1 -TestCapture                   # saves one frame so you can check it shows the SteamVR view
  .\start_stream.ps1
  .\start_stream.ps1 -Encoder amf -BitrateMbps 80
  .\start_stream.ps1 -Fps 90 -BitrateMbps 70        # if the phone's decoder can't keep up with 120
#>
param(
  [string]$PhoneIp,
  [int]$Port = 5000,
  [int]$Fps = 120,
  [int]$Width = 2992,
  [int]$Height = 1344,
  [int]$Adapter = -1,
  [int]$OutputIdx = -1,
  [double]$BitrateMbps = 100,
  [ValidateSet('auto', 'nvenc', 'amf', 'qsv')][string]$Encoder = 'auto',
  [int]$Gop = 60,
  [string]$FfmpegPath = 'ffmpeg',
  [switch]$ListDisplays,
  [switch]$TestCapture,
  [switch]$PrintOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'phonevr_common.ps1')

if (-not (Get-Command $FfmpegPath -ErrorAction SilentlyContinue)) {
  throw "ffmpeg not found. Download a full build (6.1 or newer) from https://www.gyan.dev/ffmpeg/builds/ or https://github.com/BtbN/FFmpeg-Builds/releases, then put it on PATH or use -FfmpegPath."
}

$all = @(Get-CaptureOutputs $FfmpegPath)

if ($ListDisplays) {
  "Screens ffmpeg can capture:"
  foreach ($s in $all) {
    $tag = if ($s.Width -eq $Width -and $s.Height -eq $Height) { '   <- PhoneVR virtual display' } else { '' }
    "  -Adapter {0} -OutputIdx {1}   {2}x{3}   {4}{5}" -f $s.Adapter, $s.Output, $s.Width, $s.Height, $s.Gpu, $tag
  }
  ""
  "Your local IPv4 address(es), to type into the phone app:"
  Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
    ForEach-Object { "  " + $_.IPAddress + "  (" + $_.InterfaceAlias + ")" }
  return
}

if ($Adapter -ge 0 -or $OutputIdx -ge 0) {
  $a = [math]::Max($Adapter, 0); $o = [math]::Max($OutputIdx, 0)
  $capture = $all | Where-Object { $_.Adapter -eq $a -and $_.Output -eq $o } | Select-Object -First 1
  if (-not $capture) { throw "No screen at -Adapter $a -OutputIdx $o. See -ListDisplays." }
  if ($capture.Width -ne $Width -or $capture.Height -ne $Height) {
    Write-Warning "That screen is $($capture.Width)x$($capture.Height), not ${Width}x${Height}: the phone will show that screen, not the SteamVR view."
  }
} else {
  $capture = $all | Where-Object { $_.Width -eq $Width -and $_.Height -eq $Height } | Select-Object -First 1
  if (-not $capture) { Write-NoVirtualDisplayHelp $all $Width $Height; exit 1 }
}
$enc = Resolve-Encoder $Encoder $capture

if ($TestCapture) {
  $png = Join-Path (Get-Location) 'phonevr_capture_test.png'
  Invoke-FfmpegText $FfmpegPath ("-hide_banner -loglevel error -y -init_hw_device d3d11va=dx:$($capture.Adapter) -filter_hw_device dx " +
    "-filter_complex ddagrab=output_idx=$($capture.Output):framerate=5:draw_mouse=0,hwdownload,format=bgra -frames:v 1 `"$png`"") | Out-Null
  if (Test-Path $png) { Write-Host "Saved $png - it should show the SteamVR headset view (two eye images side by side)."; Start-Process $png }
  else { Write-Warning "Capture failed. See -ListDisplays." }
  return
}

if ($PrintOnly) {
  "$FfmpegPath " + ((Get-FfmpegArgs -Ip '<phone-ip>' -Capture $capture -Encoder $enc -Fps $Fps -BitrateMbps $BitrateMbps -Gop $Gop -Port $Port) -join ' ')
  return
}

Write-Host ("PhoneVR stream: GPU {0} screen {1} ({2}x{3}) @ {4} fps, {5}, {6} Mbps -> UDP port {7}. Ctrl+C to stop." -f `
  $capture.Adapter, $capture.Output, $capture.Width, $capture.Height, $Fps, $enc, [int]$BitrateMbps, $Port)
Start-StreamLoop -Ffmpeg $FfmpegPath -Capture $capture -Encoder $enc -Fps $Fps -BitrateMbps $BitrateMbps -Gop $Gop -Port $Port `
  -PhoneIpOverride $PhoneIp
