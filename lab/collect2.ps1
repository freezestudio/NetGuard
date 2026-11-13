$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\test-result.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 收集结果 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "已强制断电" }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
L "系统盘: $target"
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"
L "分区: $root"

$res = "$root\NetGuard\result.txt"
if (Test-Path $res) {
    L "--- result.txt ---"
    Get-Content $res | ForEach-Object { L "  $_" }
} else {
    L "无 result.txt"
    Get-ChildItem "$root\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }
}

[GC]::Collect()
Dismount-VHD -Path $target
L "完成"
