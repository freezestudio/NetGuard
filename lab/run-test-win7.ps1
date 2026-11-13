$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\test-win7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 现场测试夹具 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$exe    = "$RepoRoot\build\NetGuard.exe"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 5; L "已关机" }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"
L "Windows 分区: $root"

# 1) 投放文件
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item $exe "$ng\NetGuard.exe" -Force
L "已投放 NetGuard.exe"

$policy = @'
; NetGuard test policy
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=测试业务
Cidr=10.0.0.1/32
Ports=80
Proto=TCP
Enable=1

[ep.2]
Name=内网打印机
Cidr=10.0.0.2/32
Ports=9100
Proto=TCP
Enable=1

[proc.1]
Name=记事本（测试）
Path=C:\Windows\System32\notepad.exe
Sha256=
Endpoint=测试业务
Enable=1
'@
[IO.File]::WriteAllText("$pd\policy.ini", ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L "已写 policy.ini（ProgramData）"

$test = @'
@echo off
setlocal
set R=C:\NetGuard\result.txt
cd /d C:\NetGuard
echo ===== NetGuard 测试 %DATE% %TIME% > "%R%"
echo. >> "%R%"
echo --- [0] sign (per-install key) --- >> "%R%"
NetGuard.exe sign >> "%R%" 2>&1
echo sign exit=%ERRORLEVEL% >> "%R%"
echo. >> "%R%"
echo --- [1] status (before) --- >> "%R%"
NetGuard.exe status >> "%R%" 2>&1
echo. >> "%R%"
echo --- [2] apply --- >> "%R%"
NetGuard.exe apply >> "%R%" 2>&1
echo apply exit=%ERRORLEVEL% >> "%R%"
echo. >> "%R%"
echo --- [3] selftest (期望全部拦截) --- >> "%R%"
NetGuard.exe selftest >> "%R%" 2>&1
echo. >> "%R%"
echo --- [4] status (after apply) --- >> "%R%"
NetGuard.exe status >> "%R%" 2>&1
echo. >> "%R%"
echo --- [5] rollback --- >> "%R%"
NetGuard.exe rollback >> "%R%" 2>&1
echo. >> "%R%"
echo --- [6] selftest (期望恢复连接) --- >> "%R%"
NetGuard.exe selftest >> "%R%" 2>&1
echo. >> "%R%"
echo --- [7] 恢复 UAC / 清理 RunOnce --- >> "%R%"
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f >> "%R%" 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgTest /f >> "%R%" 2>&1
echo ===== DONE %DATE% %TIME% >> "%R%"
shutdown /s /t 15 /f
'@
[IO.File]::WriteAllText("$ng\test.cmd", ($test -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
L "已写 test.cmd"

# 2) 离线改注册表：关 UAC + RunOnce
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NGTEST' $sw 2>&1 | Out-Null
if ($?) {
    Set-ItemProperty 'HKLM:\NGTEST\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -Type DWord
    Set-ItemProperty 'HKLM:\NGTEST\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '1' -Type String
    Set-ItemProperty 'HKLM:\NGTEST\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty 'HKLM:\NGTEST\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -Value '1' -Type String
    New-Item -Path 'HKLM:\NGTEST\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\NGTEST\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgTest -Value 'C:\NetGuard\test.cmd' -Type String
    L "注册表：UAC=0 / 自动登录 / RunOnce=NgTest"
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NGTEST' 2>&1 | Out-Null
    L "注册表已卸载"
} else { L "注册表加载失败" }

[GC]::Collect()
Dismount-VHD -Path $target
L "磁盘已卸载"

Start-VM -Name $vmName
L "VM 已启动，等待客户机自动测试（约 2-4 分钟，跑完会自行关机）"
