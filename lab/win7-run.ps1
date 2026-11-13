$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-run.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 键盘驱动运行 NetGuard test ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W5 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@

$vmName = 'Win7-Pro-x64'
$vhd    = "C:\VMs\$vmName\disk.vhdx"
$exe    = 'C:\src\NetGuard\build\NetGuard.exe'

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

# ---- 离线：禁用服务（避免它抢先下发策略）、投放文件、清理旧标记 ----
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Remove-Item "$ng\TESTONCE.flag", "$ng\result.txt" -Force -ErrorAction SilentlyContinue
Copy-Item $exe "$ng\NetGuard.exe" -Force
L "已投放 exe（服务禁用，用 CLI 测试）"

# 禁用 NetGuard 服务
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NGSYS7' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\NGSYS7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $svcKey = "HKLM:\NGSYS7\ControlSet00$cur\Services\NetGuard"
    if (Test-Path $svcKey) { Set-ItemProperty $svcKey -Name Start -Value 4 -Type DWord; L "服务已设为禁用(Start=4)" }
    else { L "服务键不存在（无妨）" }
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\NGSYS7' 2>&1 | Out-Null
}

# 确认自动登录
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NGW7' $sw 2>&1 | Out-Null
if ($?) {
    $wl = 'HKLM:\NGW7\Microsoft\Windows NT\CurrentVersion\Winlogon'
    L "AutoAdminLogon=$((Get-ItemProperty $wl -Name AutoAdminLogon -EA SilentlyContinue).AutoAdminLogon)  User=$((Get-ItemProperty $wl -Name DefaultUserName -EA SilentlyContinue).DefaultUserName)  Domain=$((Get-ItemProperty $wl -Name DefaultDomainName -EA SilentlyContinue).DefaultDomainName)"
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\NGW7' 2>&1 | Out-Null
}

[GC]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载"

# ---- 开机并驱动 ----
Start-VM -Name $vmName
L "等待自动登录到桌面（120 秒）"
Start-Sleep -Seconds 120

function Focus() {
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $vc) { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName; Start-Sleep 12; $vc = Get-Process vmconnect | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
    if ($vc) {
        [W5]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
        [W5]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
        [W5]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 600
    } else { L "  !! 无 VMConnect 窗口" }
}
function Send([string]$k, $desc) { Focus; L "  发送 [$desc]"; [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 800 }

L "[1] 打开开始菜单（Ctrl+Esc）"
Send '^{ESC}' 'start'
Start-Sleep -Seconds 2

L "[2] 输入 cmd 并回车"
Send 'cmd' 'cmd'
Send '{ENTER}' 'enter'
Start-Sleep -Seconds 3

L "[3] 运行测试并落盘"
Send 'C:\NetGuard\NetGuard.exe test > C:\NetGuard\result.txt 2>&1' 'test'
Send '{ENTER}' 'enter'
Start-Sleep -Seconds 30

L "[4] 关机"
Send 'shutdown /s /t 5 /f' 'shutdown'
Send '{ENTER}' 'enter'

for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep 10
    if ((Get-VM -Name $vmName).State -eq 'Off') { L "已关机"; break }
}
$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

# ---- 回收 ----
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$res = "$root\NetGuard\result.txt"
L "--- result.txt ---"
if (Test-Path $res) { Get-Content $res -Encoding Default | ForEach-Object { L "  $_" } } else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
