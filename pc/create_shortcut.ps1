$wsh = New-Object -ComObject WScript.Shell
$desktop = [System.Environment]::GetFolderPath('Desktop')
$scPath = Join-Path $desktop 'PhoneVR.lnk'
$sc = $wsh.CreateShortcut($scPath)
$sc.TargetPath = 'c:\Users\ali_e\Downloads\phonevr\phonevr\Start_PhoneVR.bat'
$sc.WorkingDirectory = 'c:\Users\ali_e\Downloads\phonevr\phonevr'
$sc.Description = 'Start PhoneVR Server & Stream'
$iconPath = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\vrmonitor.exe'
if (Test-Path $iconPath) {
    $sc.IconLocation = "$iconPath,0"
}
$sc.Save()
Write-Host "Created shortcut: $scPath"
