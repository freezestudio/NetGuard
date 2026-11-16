$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-autologon.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 修自动登录 + 服务测试 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"
$exe    = "$RepoRoot\build\NetGuard.exe"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "已关机" }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$winL = ($winPart | Get-Volume).DriveLetter
$root = "$($winL):"

# --- 读真实计算机名 ---
$compName = $null
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NGSYS7' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\NGSYS7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $cn = Get-ItemProperty "HKLM:\NGSYS7\ControlSet00$cur\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue
    $compName = $cn.ComputerName
    L "真实计算机名: $(if ($compName) { $compName } else { '(未读到)' })"
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\NGSYS7' 2>&1 | Out-Null
} else { L "SYSTEM hive 加载失败" }

# --- 修 Winlogon ---
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NGW7' $sw 2>&1 | Out-Null
if ($?) {
    $wl = 'HKLM:\NGW7\Microsoft\Windows NT\CurrentVersion\Winlogon'
    L "--- 当前 Winlogon 值 ---"
    foreach ($n in 'AutoAdminLogon', 'DefaultUserName', 'DefaultPassword', 'DefaultDomainName', 'AutoLogonCount', 'ForceAutoLogon') {
        $val = (Get-ItemProperty $wl -Name $n -ErrorAction SilentlyContinue).$n
        L "  $n = $(if ($null -ne $val) { $val } else { '(无)' })"
    }

    Set-ItemProperty $wl -Name AutoAdminLogon   -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultUserName  -Value 'freeze' -Type String
    Set-ItemProperty $wl -Name DefaultPassword  -Value '1' -Type String
    if ($compName) { Set-ItemProperty $wl -Name DefaultDomainName -Value $compName -Type String }
    Set-ItemProperty $wl -Name ForceAutoLogon   -Value '1' -Type String
    Remove-ItemProperty $wl -Name AutoLogonCount -ErrorAction SilentlyContinue
    # 关闭"必须按 Ctrl+Alt+Del"（域策略/本地策略）
    $sysKey = 'HKLM:\NGW7\Microsoft\Windows\CurrentVersion\Policies\System'
    New-Item -Path $sysKey -Force | Out-Null
    Set-ItemProperty $sysKey -Name DisableCAD -Value 1 -Type DWord
    Set-ItemProperty $sysKey -Name EnableLUA -Value 0 -Type DWord
    L "已写入 AutoAdminLogon=1 / freeze / 1 / 域=$(if ($compName) { $compName } else { '(空)' }) / ForceAutoLogon=1 / DisableCAD=1"

    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NGW7' 2>&1 | Out-Null
    L "注册表已卸载"
} else { L "SOFTWARE hive 加载失败" }

# --- 重新投放 exe + 测试标记（顺便验证 sublayer 变体）---
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item $exe "$ng\NetGuard.exe" -Force
Set-Content "$ng\TESTONCE.flag" 'go' -Encoding ascii
Remove-Item "$pd\selftest.txt", "$pd\ng.log" -Force -ErrorAction SilentlyContinue
L "已更新 exe + TESTONCE.flag"

[GC]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载"

Start-VM -Name $vmName
L "开机中，等待 260 秒（启动+自动登录+服务测试）"
Start-Sleep -Seconds 260

$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

foreach ($f in 'selftest.txt', 'ng.log') {
    $p = "$root\ProgramData\NetGuard\$f"
    L "--- $f ---"
    if (Test-Path $p) { Get-Content $p -Encoding UTF8 | Select-Object -Last 35 | ForEach-Object { L "  $_" } } else { L "  (缺失)" }
}
L "TESTONCE.flag 还在? $(Test-Path "$root\NetGuard\TESTONCE.flag")"
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
