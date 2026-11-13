$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win10-hostnet.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== host network diag $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8
try { L ("SharedAccess: " + (Get-Service SharedAccess -ErrorAction SilentlyContinue).Status) } catch { L "SharedAccess: $($_.Exception.Message)" }
L "--- IPv4 addresses ---"
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
L "--- adapters ---"
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
L "--- NetNat ---"
Get-NetNat | Format-List | Out-String | ForEach-Object { L $_ }
L "--- switches ---"
Get-VMSwitch | Select-Object Name, SwitchType | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
L "--- host tcp 8.8.8.8:53 ---"
$r = Test-NetConnection -ComputerName 8.8.8.8 -Port 53 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
L "host TcpTestSucceeded=$($r.TcpTestSucceeded) PingSucceeded=$($r.PingSucceeded)"
L "DONE"
