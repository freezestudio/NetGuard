$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\fix7.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 引导诊断/修复 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已强制关机" }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
foreach ($p in $parts) {
    $vol = $p | Get-Volume -ErrorAction SilentlyContinue
    L ("分区{0} 类型={1} 大小={2}MB FS={3} 盘符={4}" -f $p.PartitionNumber, $p.Type, [int]($p.Size/1MB), $vol.FileSystem, $vol.DriveLetter)
}
$winPart = $parts | Sort-Object Size -Descending | Select-Object -First 1
$srPart  = $parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1
$winL = ($winPart | Get-Volume).DriveLetter
$srL  = ($srPart  | Get-Volume).DriveLetter
L "Windows=$($winL):  系统保留=$($srL):"

L "--- 脏位 ---"
& fsutil dirty query "${winL}:" 2>&1 | ForEach-Object { L "  $_" }
if ($srL) { & fsutil dirty query "${srL}:" 2>&1 | ForEach-Object { L "  $_" } }

L "--- 休眠文件 ---"
foreach ($f in "$($winL):\hiberfil.sys", "$($winL):\pagefile.sys", "$($winL):\swapfile.sys") {
    if (Test-Path $f) { L ("  存在 {0}  {1:N0} MB" -f $f, ((Get-Item $f -Force).Length/1MB)) } else { L "  不存在 $f" }
}

L "--- BCD ---"
if ($srL) {
    (& bcdedit /store "$($srL):\Boot\BCD" /enum all 2>&1) |
        Select-String -Pattern 'identifier|description|device|path|timeout|resumeobject' |
        ForEach-Object { L "  $_" }
}

L "--- 关键文件 ---"
foreach ($f in "$($winL):\Windows\System32\winload.exe", "$($winL):\Windows\System32\config\SYSTEM",
               "$($winL):\bootmgr", "$($winL):\Boot\BCD") {
    L "  $(Test-Path $f)  $f"
}

# 删除休眠文件（有则删）
$hib = "$($winL):\hiberfil.sys"
if (Test-Path $hib) {
    try { & fsutil file setvaliddata $hib 0 2>&1 | Out-Null } catch {}
    Remove-Item $hib -Force -ErrorAction SilentlyContinue
    if (Test-Path $hib) { L "  [!] hiberfil.sys 删除失败（可能被锁定）" } else { L "  已删除 hiberfil.sys" }
}

[GC]::Collect()
Dismount-VHD -Path $target
L "已卸载"
L "完成"
