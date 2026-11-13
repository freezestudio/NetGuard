param([int]$Port = 45679, [string]$LogPath = 'C:\src\NetGuard\lab\udp-echo.log')
$ErrorActionPreference = 'SilentlyContinue'
function L($m) { Add-Content -Path $LogPath -Value ('{0}  {1}' -f (Get-Date -Format o), $m) -Encoding UTF8 }
$u = New-Object Net.Sockets.UdpClient($Port)
L ('udp listening on ' + $Port)
$ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
while ($true) {
    $b = $u.Receive([ref]$ep)
    $s = [Text.Encoding]::ASCII.GetString($b)
    L ('recv from ' + $ep.Address + ':' + $ep.Port + ' data=' + $s)
    $u.Send($b, $b.Length, $ep) | Out-Null
}
