$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\check2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 状态核实 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
L "VM 状态: $($vm.State)"
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 7; L "已断电" }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

L "--- Prefetch 最近 6 个（证明是否进过系统）---"
Get-ChildItem "$root\Windows\Prefetch" -Filter '*.pf' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 6 |
    ForEach-Object { L "  $($_.LastWriteTime)  $($_.Name)" }

L "--- 启动修复日志 ---"
$srt = "$root\Windows\System32\LogFiles\Srt\SrtTrail.txt"
if (Test-Path $srt) {
    L ("  存在，修改时间 " + (Get-Item $srt).LastWriteTime)
    Get-Content $srt -Tail 25 | ForEach-Object { L "    $_" }
} else { L "  无 SrtTrail.txt" }

L "--- 网络/服务痕迹 ---"
if (Test-Path "$root\ProgramData\NetGuard") {
    Get-ChildItem "$root\ProgramData\NetGuard" | ForEach-Object { L "  $($_.Name) $($_.Length)" }
    foreach ($f in 'selftest.txt', 'ng.log') {
        $p = "$root\ProgramData\NetGuard\$f"
        if (Test-Path $p) { L "--- $f ---"; Get-Content $p -Tail 40 | ForEach-Object { L "  $_" } }
    }
} else { L "  ProgramData\NetGuard 不存在（服务未运行）" }

L "--- TESTONCE.flag 是否还在 ---"
L "  $(Test-Path "$root\NetGuard\TESTONCE.flag")"

[GC]::Collect()
Dismount-VHD -Path $target
L "完成"
