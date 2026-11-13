$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\test-result.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 收集测试结果 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'

# 等客户机自己关机（最多 10 分钟）
for ($i = 0; $i -lt 60; $i++) {
    $st = (Get-VM -Name $vmName).State
    if ($st -eq 'Off') { L "客户机已自行关机（等待 $($i * 10) 秒）"; break }
    Start-Sleep -Seconds 10
}
$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') {
    L "超时未关机，强制断电后读取"
    Stop-VM -Name $vmName -TurnOff -Force
    Start-Sleep 6
}

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru -ErrorAction SilentlyContinue
if (-not $v) { L "挂载失败（磁盘可能仍被占用）"; exit 1 }
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

$res = "$root\NetGuard\result.txt"
if (Test-Path $res) {
    L "--- result.txt ---"
    Get-Content $res | ForEach-Object { L "  $_" }
} else {
    L "找不到 result.txt —— 客户机可能没跑到测试"
    Get-ChildItem "$root\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  文件: $($_.Name) $($_.Length)" }
}

[GC]::Collect()
Dismount-VHD -Path $target
L "已卸载"
L "完成"
