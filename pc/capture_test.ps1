<#
.SYNOPSIS
  Saves one frame from every screen ffmpeg can capture (phonevr_capture_<gpu>_<screen>.png), so you can see which
  one shows the SteamVR headset view. The PhoneVR virtual display is the one at 2992x1344.
#>
param([string]$Ffmpeg = 'ffmpeg')

. (Join-Path $PSScriptRoot 'phonevr_common.ps1')

$all = @(Get-CaptureOutputs $Ffmpeg)
if ($all.Count -eq 0) { Write-Host "FAILED_TO_CAPTURE (ffmpeg could not open any screen)"; exit 1 }

foreach ($s in $all) {
  $png = Join-Path (Get-Location) ("phonevr_capture_{0}_{1}.png" -f $s.Adapter, $s.Output)
  if (Test-Path $png) { Remove-Item $png -Force }
  Invoke-FfmpegText $Ffmpeg ("-hide_banner -loglevel error -y -init_hw_device d3d11va=dx:$($s.Adapter) -filter_hw_device dx " +
    "-filter_complex ddagrab=output_idx=$($s.Output):framerate=5:draw_mouse=0,hwdownload,format=bgra -frames:v 1 `"$png`"") | Out-Null
  $status = if (Test-Path $png) { "SAVED_CAPTURE: $png" } else { "FAILED_TO_CAPTURE" }
  Write-Host ("GPU {0} ({1}) screen {2} {3}x{4}: {5}" -f $s.Adapter, $s.Gpu, $s.Output, $s.Width, $s.Height, $status)
}
