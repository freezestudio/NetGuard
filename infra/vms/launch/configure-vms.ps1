# 配置两台虚拟机：自动登录、RDP/剪贴板、固定 IP、单 VM 启动。
# 由提权 worker 运行（需要 Mount-VHD / 注册表 / Hyper-V 权限）。
$ErrorActionPreference = 'Stop'
$log = 'C:\VMs\launch\configure-vms.log'
function L([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
function Wait-VmState([string]$name, [string]$state, [int]$seconds = 120) {
    for ($i = 0; $i -lt $seconds; $i++) {
        Start-Sleep 1
        if ((Get-VM -Name $name -ErrorAction SilentlyContinue).State -eq $state) { return $true }
    }
    return $false
}
function Wait-Rdp([string]$ip, [int]$seconds = 150) {
    for ($i = 0; $i -lt $seconds; $i++) {
        $c = New-Object Net.Sockets.TcpClient
        try {
            $ar = $c.BeginConnect($ip, 3389, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(1500)) {
                $c.EndConnect($ar)
                $c.Close()
                return $true
            }
        } catch { }
        try { $c.Close() } catch { }
        Start-Sleep 2
    }
    return $false
}
function Stop-AllVms {
    foreach ($n in @('Win7-Pro-x64', 'Win10-Pro-22H2')) {
        $v = Get-VM -Name $n -ErrorAction SilentlyContinue
        if ($v -and $v.State -ne 'Off') {
            L ('stopping ' + $n + ' (state=' + $v.State + ')')
            try { Stop-VM -Name $n -TurnOff -Force -ErrorAction Stop } catch { }
            Start-Sleep 2
        }
    }
    Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

'=== configure VMs ' + (Get-Date -Format o) + ' ===' | Set-Content -Path $log -Encoding UTF8
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = New-Object Security.Principal.WindowsPrincipal($id)
L ('admin=' + $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

# 宿主机：增强会话（Win10 剪贴板）
Set-VMHost -EnableEnhancedSessionMode $true
L 'host EnhancedSessionMode=true'

# ---------------------------------------------------------------- Win7
L '--- Win7: offline auto-login / RDP / static IP ---'
Stop-AllVms
$vhd = 'C:\VMs\Win7-Pro-x64\disk.vhdx'
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L ('Win7 volume=' + $root)

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\W7CFG' $sw 2>&1 | Out-Null
if (-not $?) { throw '无法加载 Win7 SOFTWARE hive' }
$wl = 'HKLM:\W7CFG\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
Set-ItemProperty $wl -Name ForceAutoLogon -Value '1' -Type String
$sysPol = 'HKLM:\W7CFG\Microsoft\Windows\CurrentVersion\Policies\System'
New-Item -Path $sysPol -Force | Out-Null
Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
L 'Win7 auto-logon: freeze/1, EnableLUA=0, DisableCAD=1'

$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\S7CFG' $sysHive 2>&1 | Out-Null
if (-not $?) { throw '无法加载 Win7 SYSTEM hive' }
$cur = (Get-ItemProperty 'HKLM:\S7CFG\Select' -ErrorAction SilentlyContinue).Current
if (-not $cur) { $cur = 1 }
$cs = "HKLM:\S7CFG\ControlSet00$cur"
Set-ItemProperty "$cs\Control\Terminal Server" -Name fDenyTSConnections -Value 0 -Type DWord
Set-ItemProperty "$cs\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -Value 0 -Type DWord
Set-ItemProperty "$cs\Services\TermService" -Name Start -Value 2 -Type DWord
Set-ItemProperty "$cs\Services\UmRdpService" -Name Start -Value 3 -Type DWord
L 'Win7 RDP: fDenyTSConnections=0, NLA=off, TermService=auto'

$compName = (Get-ItemProperty "$cs\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
if ($compName) { Set-ItemProperty $wl -Name DefaultDomainName -Value $compName -Type String; L ('Win7 computer name=' + $compName) }

$runOnce = 'HKLM:\W7CFG\Microsoft\Windows\CurrentVersion\RunOnce'
New-Item -Path $runOnce -Force | Out-Null
Set-ItemProperty $runOnce -Name NgRdpSetup -Value 'C:\rdp-setup.cmd' -Type String
[gc]::Collect(); Start-Sleep -Milliseconds 800
& reg unload 'HKLM\W7CFG' 2>&1 | Out-Null
& reg unload 'HKLM\S7CFG' 2>&1 | Out-Null

# RunOnce 脚本：放行 RDP 防火墙 + 固定 IP
$setupPs = @'
$ErrorActionPreference = "Continue"
$out = "C:\rdp-setup.txt"
"=== rdp setup $(Get-Date -Format o) ===" | Out-File $out -Encoding ASCII
try {
    $nic = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.IPAddress -like "172.20.*" } | Select-Object -First 1
    if (-not $nic) { $nic = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | Select-Object -First 1 }
    if ($nic) {
        $r1 = $nic.EnableStatic("172.20.192.50", "255.255.240.0")
        $r2 = $nic.SetGateways("172.20.192.1", 1)
        $r3 = $nic.SetDNSServerSearchOrder("8.8.8.8")
        "static ip: $($r1.ReturnValue) gateway: $($r2.ReturnValue) dns: $($r3.ReturnValue)" | Out-File $out -Append -Encoding ASCII
    } else { "no enabled NIC" | Out-File $out -Append -Encoding ASCII }
} catch { "static ip error: $($_.Exception.Message)" | Out-File $out -Append -Encoding ASCII }
'@
[IO.File]::WriteAllText("$root\rdp-setup.ps1", ($setupPs -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))

$setupCmd = @'
@echo off
netsh advfirewall firewall delete rule name="NetGuard RDP 3389" >nul 2>&1
netsh advfirewall firewall add rule name="NetGuard RDP 3389" dir=in action=allow protocol=TCP localport=3389 profile=any >>C:\rdp-setup.txt 2>&1
netsh advfirewall firewall delete rule name="NetGuard ICMP" >nul 2>&1
netsh advfirewall firewall add rule name="NetGuard ICMP" dir=in action=allow protocol=icmpv4 profile=any >>C:\rdp-setup.txt 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\rdp-setup.ps1 >>C:\rdp-setup.txt 2>&1
sc config TermService start= auto >>C:\rdp-setup.txt 2>&1
sc start TermService >>C:\rdp-setup.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgRdpSetup /f >nul 2>&1
'@
[IO.File]::WriteAllText("$root\rdp-setup.cmd", ($setupCmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$root\rdp-setup.txt" -Force -ErrorAction SilentlyContinue
[gc]::Collect()
Dismount-VHD -Path $vhd
L 'Win7 VHD configured and dismounted'

Start-VM -Name 'Win7-Pro-x64'
L 'Win7 booting; waiting for auto-login + RunOnce + RDP ...'
$rdpOk = Wait-Rdp '172.20.192.50' 180
L ('Win7 RDP 172.20.192.50:3389 = ' + $rdpOk)
$vm = Get-VM -Name 'Win7-Pro-x64'
L ('Win7 state=' + $vm.State + ' uptime=' + $vm.Uptime)

if (-not $rdpOk) {
    # 尝试从邻居表按 MAC 找 DHCP 地址
    $macs = @()
    foreach ($a in (Get-VMNetworkAdapter -VMName 'Win7-Pro-x64' -ErrorAction SilentlyContinue)) {
        if ($a.MacAddress) { $macs += ($a.MacAddress -replace '[-:]', '').ToUpper() }
    }
    foreach ($n in (Get-NetNeighbor -InterfaceAlias 'vEthernet (Default Switch)' -ErrorAction SilentlyContinue)) {
        $m = ($n.LinkLayerAddress -replace '[-:]', '').ToUpper()
        if ($macs -contains $m) { L ('neighbor IP=' + $n.IPAddress + ' state=' + $n.State + ' rdp=' + (Wait-Rdp $n.IPAddress 10)) }
    }
}

# 读取 guest 内的 rdp-setup.txt（关机后挂载）
Stop-VM -Name 'Win7-Pro-x64' -TurnOff -Force -ErrorAction SilentlyContinue
Start-Sleep 5
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 2
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
if (Test-Path "$root\rdp-setup.txt") {
    L '--- guest rdp-setup.txt ---'
    Get-Content "$root\rdp-setup.txt" -Encoding Default | ForEach-Object { L ('  ' + $_) }
} else { L 'guest rdp-setup.txt MISSING' }
[gc]::Collect()
Dismount-VHD -Path $vhd

# ---------------------------------------------------------------- Win10
L '--- Win10: auto-login / RDP / static IP ---'
Stop-AllVms
Start-VM -Name 'Win10-Pro-22H2'
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$s = $null
for ($i = 0; $i -lt 60; $i++) {
    try { $s = New-PSSession -VMName 'Win10-Pro-22H2' -Credential $cred -ErrorAction Stop; break } catch { Start-Sleep 5 }
}
if (-not $s) { L 'Win10 PS Direct FAILED'; }
else {
    L 'Win10 PS Direct connected'
    $r = Invoke-Command -Session $s -ScriptBlock {
        $out = [ordered]@{}
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
        Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
        Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
        Set-ItemProperty $wl -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
        Set-ItemProperty $wl -Name ForceAutoLogon -Value '1' -Type String
        $sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -Type DWord
        Set-Service TermService -StartupType Automatic
        Start-Service TermService -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        $out['auto_logon'] = (Get-ItemProperty $wl).AutoAdminLogon
        $out['computer'] = $env:COMPUTERNAME
        # static IP
        try {
            $if = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' } | Select-Object -First 1).Name
            Remove-NetIPAddress -InterfaceAlias $if -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceAlias $if -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceAlias $if -IPAddress '172.20.192.51' -PrefixLength 20 -DefaultGateway '172.20.192.1' -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses '8.8.8.8' -ErrorAction SilentlyContinue
            $out['static_ip'] = (Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 | Select-Object -First 1).IPAddress
            $out['if'] = $if
        } catch {
            $out['static_ip'] = 'ERR: ' + $_.Exception.Message
        }
        [pscustomobject]$out
    }
    $r | Format-List | Out-String | ForEach-Object { L ('  ' + $_) }
    Start-Sleep 3
    $rdp10 = Wait-Rdp '172.20.192.51' 30
    L ('Win10 RDP 172.20.192.51:3389 = ' + $rdp10)
    Invoke-Command -Session $s -ScriptBlock { Stop-Computer -Force } -ErrorAction SilentlyContinue
    Remove-PSSession $s -ErrorAction SilentlyContinue
}
Wait-VmState 'Win10-Pro-22H2' 'Off' 120 | Out-Null

# 主机侧保存 RDP 凭据（剪贴板 RDP 启动器用）
& "$env:SystemRoot\System32\cmdkey.exe" /generic:'TERMSRV/172.20.192.50' /user:freeze /pass:1 | Out-Null
& "$env:SystemRoot\System32\cmdkey.exe" /generic:'TERMSRV/172.20.192.51' /user:freeze /pass:1 | Out-Null
L 'host cmdkey saved for 172.20.192.50 / 172.20.192.51'

Stop-AllVms
L '=== configure done ==='
