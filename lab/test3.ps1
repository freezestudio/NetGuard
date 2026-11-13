$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\test3.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 服务测试 v3 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$exe    = 'C:\src\NetGuard\build\NetGuard.exe'

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

Copy-Item $exe "$root\NetGuard\NetGuard.exe" -Force
Set-Content "$root\NetGuard\TESTONCE.flag" 'go' -Encoding ascii
# 清掉上次可能残留的结果
Remove-Item "$root\ProgramData\NetGuard\selftest.txt" -Force -ErrorAction SilentlyContinue
Remove-Item "$root\ProgramData\NetGuard\ng.log" -Force -ErrorAction SilentlyContinue
L "已更新 exe 并重置测试标记"

[GC]::Collect()
Dismount-VHD -Path $target
L "磁盘已卸载，启动 VM"

Start-VM -Name $vmName
L "等待 150 秒让服务完成测试"
Start-Sleep -Seconds 150

$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

foreach ($f in @('selftest.txt', 'ng.log')) {
    $p = "$root\ProgramData\NetGuard\$f"
    L "--- $f ---"
    if (Test-Path $p) { Get-Content $p -Tail 60 | ForEach-Object { L "  $_" } } else { L "  (缺失)" }
}
L "--- C:\NetGuard ---"
Get-ChildItem "$root\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }

[GC]::Collect()
Dismount-VHD -Path $target
L "完成"
