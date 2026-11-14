# Creates a "PhoneVR" shortcut on the desktop that runs Start_PhoneVR.bat from wherever this project lives.
. (Join-Path $PSScriptRoot 'phonevr_common.ps1')

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$wsh = New-Object -ComObject WScript.Shell
$desktop = [System.Environment]::GetFolderPath('Desktop')
$scPath = Join-Path $desktop 'PhoneVR.lnk'
$sc = $wsh.CreateShortcut($scPath)
$sc.TargetPath = Join-Path $root 'Start_PhoneVR.bat'
$sc.WorkingDirectory = $root
$sc.Description = 'Start PhoneVR Server & Stream'
$steamvr = Find-SteamVrDir
if ($steamvr) {
  $iconPath = Join-Path $steamvr 'bin\win64\vrmonitor.exe'
  if (Test-Path $iconPath) { $sc.IconLocation = "$iconPath,0" }
}
$sc.Save()
Write-Host "Created shortcut: $scPath -> $($sc.TargetPath)"
