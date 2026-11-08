<#
.SYNOPSIS
  Prepares a wired (USB tethering) link to the phone and measures its latency.

.DESCRIPTION
  1. On the phone: plug in USB, then Settings > Network & internet > Hotspot & tethering > USB tethering = ON.
  2. Run this script from an elevated PowerShell (admin is needed to change the network profile).

  It finds the tether adapter, marks it as a Private network (the driver's firewall rule only covers Private/Domain,
  and Windows labels new adapters Public), and prints:
    - the PC address to type into the phone app
    - the phone's address on the cable (start_stream.ps1 picks it up automatically)
  Then it pings the phone to show the round-trip time over the cable.

.EXAMPLE
  .\usb_tether.ps1
  .\usb_tether.ps1 -PingCount 100
#>
param([int]$PingCount = 50)

$ErrorActionPreference = 'Stop'

$adapter = Get-NetAdapter | Where-Object {
  $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'RNDIS|NCM|Remote NDIS|Android|Ethernet Gadget|USB Ethernet|Pixel|Google')
} | Select-Object -First 1

if (-not $adapter) {
  Write-Host "No USB tethering adapter found. Check: cable plugged in, a data cable (not charge-only), USB tethering switched ON on the phone."
  Write-Host "Adapters that are up right now:"
  Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object { "  {0}  -  {1}" -f $_.Name, $_.InterfaceDescription }
  exit 1
}

$cfg = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
$pcIp = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
$phoneIp = $cfg.IPv4DefaultGateway.NextHop | Select-Object -First 1
if (-not $pcIp -or -not $phoneIp) {
  Write-Host "Adapter '$($adapter.Name)' has no IPv4 address/gateway yet. Wait a few seconds and run again."
  exit 1
}

try {
  Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private
  Write-Host "Network '$($adapter.Name)' set to Private so the PhoneVR firewall rule applies."
} catch {
  Write-Warning "Could not set the network to Private ($($_.Exception.Message)). Run PowerShell as administrator."
}

Write-Host ""
Write-Host "Adapter     : $($adapter.Name)  ($($adapter.InterfaceDescription), link speed $($adapter.LinkSpeed))"
Write-Host "PC address  : $pcIp      <- type this into the phone app"
Write-Host "Phone address: $phoneIp   <- start_stream.ps1 -PhoneIp $phoneIp  (it normally finds this itself)"
Write-Host ""

$ms = @()
for ($i = 0; $i -lt $PingCount; $i++) {
  $r = Test-Connection -ComputerName $phoneIp -Count 1 -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($r) {
    $time = if ($null -ne $r.ResponseTime) { $r.ResponseTime } else { $r.Latency }
    if ($null -ne $time) { $ms += [double]$time }
  }
  Start-Sleep -Milliseconds 20
}
if ($ms.Count -eq 0) {
  Write-Host "The phone did not answer pings (some phones block ICMP). That does not stop PhoneVR; test with the app instead."
} else {
  $sorted = $ms | Sort-Object
  Write-Host ("Ping to phone over cable: min {0} ms, median {1} ms, max {2} ms, lost {3}/{4}" -f $sorted[0], $sorted[[int]($sorted.Count / 2)], $sorted[-1], ($PingCount - $ms.Count), $PingCount)
  Write-Host "(Windows reports whole milliseconds, so 0-1 ms means 'under about 1 ms'. Wi-Fi is typically 3-15 ms with spikes.)"
}
