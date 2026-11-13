$ErrorActionPreference='Continue'
'--- opencode processes ---'
Get-Process opencode -ErrorAction SilentlyContinue | Select-Object Id,Path,StartTime | Format-List
'--- hashes ---'
foreach ($p in (Get-Process opencode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path -Unique)) {
    if ($p -and (Test-Path $p)) {
        $h = (Get-FileHash $p -Algorithm SHA256).Hash
        "$h  $p"
    }
}
'--- established connections (opencode) ---'
$ids = @(Get-Process opencode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
  Where-Object { $ids -contains $_.OwningProcess } |
  Select-Object RemoteAddress,RemotePort,OwningProcess | Format-Table -AutoSize
'--- DNS servers ---'
Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.ServerAddresses.Count -gt 0 } |
  Select-Object InterfaceAlias,ServerAddresses | Format-Table -AutoSize
'--- host IP ---'
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object InterfaceAlias,IPAddress,PrefixLength | Format-Table -AutoSize
