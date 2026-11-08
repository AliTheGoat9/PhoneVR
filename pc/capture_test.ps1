param(
  [int]$OutputIdx = 0
)
$png = Join-Path (Get-Location) 'phonevr_capture_test.png'
if (Test-Path $png) { Remove-Item $png -Force }

# First try ffmpeg ddagrab
$ffmpeg = 'ffmpeg'
& $ffmpeg -hide_banner -loglevel warning -y -f lavfi -i "ddagrab=output_idx=${OutputIdx}:framerate=5:draw_mouse=0,hwdownload,format=bgra" -frames:v 1 $png 2>&1 | Out-Null

if (-not (Test-Path $png)) {
  # Fallback to .NET CopyFromScreen
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $screens = [System.Windows.Forms.Screen]::AllScreens
  if ($OutputIdx -ge 0 -and $OutputIdx -lt $screens.Count) {
    $s = $screens[$OutputIdx]
  } else {
    $s = [System.Windows.Forms.Screen]::PrimaryScreen
  }
  $b = New-Object System.Drawing.Bitmap($s.Bounds.Width, $s.Bounds.Height)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($s.Bounds.X, $s.Bounds.Y, 0, 0, $b.Size)
  $b.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $b.Dispose()
}

if (Test-Path $png) {
  Write-Host "SAVED_CAPTURE: $png ($((Get-Item $png).Length) bytes)"
} else {
  Write-Host "FAILED_TO_CAPTURE"
}
