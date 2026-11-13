$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\w7test-final.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 自动测试（RunOnce）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"
$exe    = "$RepoRoot\build\NetGuard.exe"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "已关机" }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "Windows: $root"

# ---- 部署文件 ----
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item $exe "$ng\NetGuard.exe" -Force
L "NetGuard.exe 已投放 ($((Get-Item "$ng\NetGuard.exe").Length) 字节)"

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=医保前置
Cidr=10.10.10.10/32
Ports=8000-8005
Proto=TCP
Enable=1

[proc.1]
Name=notepad-test
Path=C:\Windows\System32\notepad.exe
Sha256=
Endpoint=医保前置
Enable=1
"@
[IO.File]::WriteAllText("$pd\policy.ini", ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L "policy.ini 已投放: $(Test-Path "$pd\policy.ini")"

$test = @'
@echo off
cd /d C:\NetGuard
echo ===== NetGuard Win7 test > result.txt
ver >> result.txt
echo. >> result.txt
echo --- sign (per-install key) --- >> result.txt
NetGuard.exe sign >> result.txt 2>&1
echo sign exit=%ERRORLEVEL% >> result.txt
echo. >> result.txt
NetGuard.exe test >> result.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> result.txt
echo. >> result.txt
echo --- status --- >> result.txt
NetGuard.exe status >> result.txt 2>&1
echo. >> result.txt
echo --- ng.log --- >> result.txt
type C:\ProgramData\NetGuard\ng.log >> result.txt 2>&1
echo. >> result.txt
echo --- filters.txt --- >> result.txt
type C:\ProgramData\NetGuard\filters.txt >> result.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgTest /f >nul 2>&1
shutdown /s /t 25 /f
'@
[IO.File]::WriteAllText("$ng\test.cmd", ($test -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
L "test.cmd 已投放"

# ---- 注册表：禁用服务 + 关 UAC + 自动登录 + RunOnce ----
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\S7' $sysHive 2>&1 | Out-Null
$compName = $null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\S7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $svcKey = "HKLM:\S7\ControlSet00$cur\Services\NetGuard"
    if (Test-Path $svcKey) { Set-ItemProperty $svcKey -Name Start -Value 4 -Type DWord; L "服务已禁用（避免干扰）" }
    $compName = (Get-ItemProperty "HKLM:\S7\ControlSet00$cur\Control\ComputerName\ComputerName" -EA SilentlyContinue).ComputerName
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\S7' 2>&1 | Out-Null
}

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\W7' $sw 2>&1 | Out-Null
if ($?) {
    $sysPol = 'HKLM:\W7\Microsoft\Windows\CurrentVersion\Policies\System'
    New-Item -Path $sysPol -Force | Out-Null
    Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
    Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord

    $wl = 'HKLM:\W7\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon  -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
    if ($compName) { Set-ItemProperty $wl -Name DefaultDomainName -Value $compName -Type String }
    Set-ItemProperty $wl -Name ForceAutoLogon  -Value '1' -Type String

    New-Item -Path 'HKLM:\W7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\W7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgTest -Value 'C:\NetGuard\test.cmd' -Type String
    L "注册表: EnableLUA=0 / 自动登录 $compName\freeze / RunOnce=NgTest"
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\W7' 2>&1 | Out-Null
}
Remove-Item "$ng\result.txt" -Force -ErrorAction SilentlyContinue

[GC]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载"

Start-VM -Name $vmName
L "已开机，等待自动登录+测试+关机（最多 6 分钟）"
for ($i = 0; $i -lt 36; $i++) {
    Start-Sleep 10
    $st = (Get-VM -Name $vmName).State
    if ($i % 3 -eq 0) { L "  T+$($i*10)s 状态=$st" }
    if ($st -eq 'Off') { L "  客户机已自动关机"; break }
}
$st = (Get-VM -Name $vmName).State
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "强制断电" }

# ---- 回收结果 ----
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$res = "$root\NetGuard\result.txt"
L "--- result.txt ---"
if (Test-Path $res) { Get-Content $res -Encoding Default | ForEach-Object { L "  $_" } }
else {
    L "  (缺失) 目录内容:"
    Get-ChildItem "$root\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "    $($_.Name) $($_.Length)" }
    Get-ChildItem "$root\ProgramData\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "    PD: $($_.Name) $($_.Length)" }
}
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
