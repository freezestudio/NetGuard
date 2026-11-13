$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-ngtest.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 上验证 NetGuard ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$exe    = "$RepoRoot\build\NetGuard.exe"
$vmDir  = "$VmsRoot\$vmName"
$vhd    = "$vmDir\disk.vhdx"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "已关机" }

# ---- 1. 挂载并检查文件系统
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
foreach ($p in $parts) {
    $vol = $p | Get-Volume -ErrorAction SilentlyContinue
    L ("分区{0} active={1} {2}MB {3} 盘符={4}" -f $p.PartitionNumber, $p.IsActive, [int]($p.Size/1MB), $vol.FileSystem, $vol.DriveLetter)
}
$winPart = $parts | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$winL = ($winPart | Get-Volume).DriveLetter
if (-not $winL) { Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $winPart.PartitionNumber -AccessPath 'W:\' | Out-Null; Start-Sleep 2; $winL = 'W' }
$root = "$($winL):"
L "Windows 分区: $root"

L "--- chkdsk $($winL): /f ---"
& chkdsk "$($winL):" /f 2>&1 | Select-Object -Last 3 | ForEach-Object { L "  $_" }

# ---- 2. 投放文件
$ng = "$root\NetGuard"
$pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item $exe "$ng\NetGuard.exe" -Force
L "已投放 NetGuard.exe"

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
Name=记事本（占位）
Path=C:\Windows\System32\notepad.exe
Sha256=
Endpoint=医保前置
Enable=1
"@
[IO.File]::WriteAllText("$pd\policy.ini", ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L "已投放 policy.ini"

$test = @'
@echo off
cd /d C:\NetGuard
echo ===== NetGuard on Win7 %DATE% %TIME% > C:\NetGuard\result.txt
ver >> C:\NetGuard\result.txt
echo. >> C:\NetGuard\result.txt
NetGuard.exe test >> C:\NetGuard\result.txt 2>&1
echo test exit=%ERRORLEVEL% >> C:\NetGuard\result.txt
echo. >> C:\NetGuard\result.txt
NetGuard.exe status >> C:\NetGuard\result.txt 2>&1
echo. >> C:\NetGuard\result.txt
echo --- ng.log --- >> C:\NetGuard\result.txt
type C:\ProgramData\NetGuard\ng.log >> C:\NetGuard\result.txt 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f >> C:\NetGuard\result.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgTest /f >> C:\NetGuard\result.txt 2>&1
echo ===== DONE %DATE% %TIME% >> C:\NetGuard\result.txt
shutdown /s /t 20 /f
'@
[IO.File]::WriteAllText("$ng\test.cmd", ($test -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
L "已投放 test.cmd"

# ---- 3. 离线注册表：关 UAC + 自动登录 + RunOnce
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NGW7' $sw 2>&1 | Out-Null
if ($?) {
    Set-ItemProperty 'HKLM:\NGW7\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -Type DWord
    $wl = 'HKLM:\NGW7\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
    Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
    Set-ItemProperty $wl -Name DefaultDomainName -Value 'WIN7-PC' -Type String
    New-Item -Path 'HKLM:\NGW7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\NGW7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgTest -Value 'C:\NetGuard\test.cmd' -Type String
    L "注册表：EnableLUA=0 / 自动登录 freeze / RunOnce=NgTest"
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NGW7' 2>&1 | Out-Null
    L "注册表已卸载"
} else { L "注册表加载失败" }

[GC]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载"

# ---- 4. 开机等待自动测试
Start-VM -Name $vmName
L "已开机，等待 150 秒（启动 + 登录 + 测试）"
Start-Sleep -Seconds 150
for ($i = 0; $i -lt 20; $i++) {
    if ((Get-VM -Name $vmName).State -eq 'Off') { L "客户机已自动关机"; break }
    Start-Sleep 15
}
$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

# ---- 5. 回收结果
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$winL = ($winPart | Get-Volume).DriveLetter
$res = "$($winL):\NetGuard\result.txt"
L "--- result.txt ---"
if (Test-Path $res) { Get-Content $res -Encoding Default | ForEach-Object { L "  $_" } }
else {
    L "  没有 result.txt"
    Get-ChildItem "$($winL):\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }
}
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
