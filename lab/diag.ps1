$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\diag.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 现场勘查 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$winPart = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
$root = "$((($winPart | Get-Volume).DriveLetter)):"

L "--- 客户机是否真的启动过（关键文件 mtime）---"
foreach ($f in "$root\Windows\System32\winevt\Logs\System.evt", "$root\Windows\System32\config\SYSTEM",
               "$root\Windows\WindowsUpdate.log", "$root\Windows\Logs\CBS\CBS.log") {
    if (Test-Path $f) { L ("  {0}  {1}" -f (Get-Item $f).LastWriteTime, (Split-Path -Leaf $f)) }
}
L "--- Prefetch 痕迹 ---"
Get-ChildItem "$root\Windows\Prefetch" -Filter 'NETGUARD*' -ErrorAction SilentlyContinue |
    ForEach-Object { L "  $($_.Name)  $($_.LastWriteTime)" }
Get-ChildItem "$root\Windows\Prefetch" -Filter '*.pf' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
    ForEach-Object { L "  (最近) $($_.Name)  $($_.LastWriteTime)" }

L "--- 服务注册项回读 ---"
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\NGDIAG' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\NGDIAG\Select' -ErrorAction SilentlyContinue).Current
    L "  Select\Current = $cur"
    $svcRoot = "HKLM:\NGDIAG\ControlSet00$cur\Services"
    $found = Get-ChildItem $svcRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'NetGuard' }
    if ($found) {
        foreach ($k in $found) {
            L "  找到服务键: $($k.PSPath)"
            Get-ItemProperty $k.PSPath | Select-Object Type, Start, ErrorControl, ImagePath, ObjectName, DisplayName |
                Format-List | Out-String | ForEach-Object { L ("  " + ($_ -replace "`r`n", "`r`n  ")) }
        }
    } else { L "  !! 没有找到 NetGuard 服务键" }
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\NGDIAG' 2>&1 | Out-Null
} else { L "  hive 加载失败" }

L "--- ProgramData\\NetGuard ---"
if (Test-Path "$root\ProgramData\NetGuard") {
    Get-ChildItem "$root\ProgramData\NetGuard" | ForEach-Object { L "  $($_.Name) $($_.Length)" }
} else { L "  (目录不存在)" }

[GC]::Collect()
Dismount-VHD -Path $target
L "完成"
