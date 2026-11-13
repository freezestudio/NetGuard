param([int]$Port = 45678, [string]$LogPath = 'C:\src\NetGuard\lab\tcp-echo.log')
$ErrorActionPreference = 'SilentlyContinue'
function L($m) { Add-Content -Path $LogPath -Value ('{0}  {1}' -f (Get-Date -Format o), $m) -Encoding UTF8 }
$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
$l.Start()
L ('tcp listening on ' + $Port)
while ($true) {
    $c = $l.AcceptTcpClient()
    L ('accepted ' + $c.Client.RemoteEndPoint)
    $ns = $c.GetStream()
    $buf = New-Object byte[] 4096
    try {
        while (($n = $ns.Read($buf, 0, 4096)) -gt 0) {
            $s = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
            L ('recv ' + $s)
            $ns.Write($buf, 0, $n)
            $ns.Flush()
        }
    } catch { L ('read-error ' + $_.Exception.Message) }
    L 'closed'
    $c.Close()
}
