$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\test2-result.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 读取 Win7 测试结果 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
L "等待客户机开机并执行服务测试（120 秒）"
Start-Sleep -Seconds 120

$st = (Get-VM -Name $vmName).State
L "VM 状态: $st"
if ($st -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

$res = "$root\ProgramData\NetGuard\selftest.txt"
$nglog = "$root\ProgramData\NetGuard\ng.log"

L "--- selftest.txt ---"
if (Test-Path $res) { Get-Content $res | ForEach-Object { L "  $_" } } else { L "  (缺失)" }

L "--- ng.log（末尾 40 行）---"
if (Test-Path $nglog) { Get-Content $nglog -Tail 40 | ForEach-Object { L "  $_" } } else { L "  (缺失)" }

L "--- C:\NetGuard 目录 ---"
Get-ChildItem "$root\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }

[GC]::Collect()
Dismount-VHD -Path $target
L "完成"
