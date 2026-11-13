$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win10-netdiag.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win10 network diag $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8

$vmName = 'Win10-Pro-22H2'
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred -ErrorAction Stop
L "PS Direct ready"

Invoke-Command -Session $s -ScriptBlock {
    '--- ipconfig ---'
    & ipconfig /all
    '--- route ---'
    & route print -4
    '--- services/processes ---'
    & sc.exe query NetGuard
    Get-Process NetGuard -ErrorAction SilentlyContinue | Select-Object Id, ProcessName
    '--- ping gateway ---'
    & ping -n 2 172.30.18.1
    '--- ping 8.8.8.8 ---'
    & ping -n 2 8.8.8.8
    '--- test tcp 8.8.8.8:53 ---'
    $r = Test-NetConnection -ComputerName 8.8.8.8 -Port 53 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    "TcpTestSucceeded=$($r.TcpTestSucceeded) PingSucceeded=$($r.PingSucceeded)"
    '--- netguard filters.txt ---'
    if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') { Get-Content 'C:\ProgramData\NetGuard\filters.txt' }
} | ForEach-Object { L "  $_" }

# 宿主侧：Default Switch / NAT
try { Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription | Format-List | Out-String | ForEach-Object { L $_ } } catch { L "Get-VMSwitch: $($_.Exception.Message)" }
try { Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix | Format-List | Out-String | ForEach-Object { L $_ } } catch { L "Get-NetNat: $($_.Exception.Message)" }
try { Get-VMNetworkAdapter -VMName $vmName | Select-Object Name, SwitchName, Status, IPAddresses | Format-List | Out-String | ForEach-Object { L $_ } } catch { L "adapter: $($_.Exception.Message)" }

Remove-PSSession $s
L "DONE"
