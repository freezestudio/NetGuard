$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-svc.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 服务形态验证 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$exe    = "$RepoRoot\build\NetGuard.exe"
$vhd    = "$VmsRoot\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "已关机" }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$winL = ($winPart | Get-Volume).DriveLetter
$root = "$($winL):"
L "Windows: $root"

# 投放程序（已在则覆盖）+ 测试标记
$ng = "$root\NetGuard"
$pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item $exe "$ng\NetGuard.exe" -Force
Set-Content "$ng\TESTONCE.flag" 'go' -Encoding ascii
Remove-Item "$pd\selftest.txt", "$pd\ng.log" -Force -ErrorAction SilentlyContinue
L "已投放 exe + TESTONCE.flag"

# 注册服务（SYSTEM hive）
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NGSYS7' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\NGSYS7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $csKey = "HKLM:\NGSYS7\ControlSet00$cur\Services\NetGuard"
    New-Item -Path $csKey -Force | Out-Null
    Set-ItemProperty $csKey -Name Type         -Value 0x10 -Type DWord
    Set-ItemProperty $csKey -Name Start        -Value 2 -Type DWord
    Set-ItemProperty $csKey -Name ErrorControl -Value 1 -Type DWord
    Set-ItemProperty $csKey -Name ImagePath    -Value 'C:\NetGuard\NetGuard.exe' -Type ExpandString
    Set-ItemProperty $csKey -Name ObjectName   -Value 'LocalSystem' -Type String
    Set-ItemProperty $csKey -Name DisplayName  -Value 'NetGuard Egress Control' -Type String
    L "已注册服务到 ControlSet00$cur"
    # 顺便保持自动登录（便于后续人工观察）
    $wl = 'HKLM:\NGSYS7\WOW6432Node'   # 占位，避免误改
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NGSYS7' 2>&1 | Out-Null
    L "SYSTEM hive 已卸载"
} else { L "SYSTEM hive 加载失败" }

[GC]::Collect()
Dismount-VHD -Path $vhd
L "磁盘已卸载"

Start-VM -Name $vmName
L "已开机；服务会在启动时执行 测试前自检→应用→测试后自检→回滚→再次自检"
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
    if (Test-Path $p) { Get-Content $p -Encoding UTF8 | Select-Object -Last 40 | ForEach-Object { L "  $_" } }
    else { L "  (缺失)" }
}
L "--- TESTONCE.flag 是否还在 ---"
L "  $(Test-Path "$root\NetGuard\TESTONCE.flag")"

[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
