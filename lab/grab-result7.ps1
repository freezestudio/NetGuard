$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference='Continue'
$log="$RepoRoot\lab\result7.log"
function L($m){ "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 读取 Win7 测试结果 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8
$vmName='Win7-Pro-x64'; $vhd="$VmsRoot\$vmName\disk.vhdx"
$vm=Get-VM -Name $vmName
if($vm.State -ne 'Off'){ Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }
$v=Mount-VHD -Path $vhd -Passthru; Start-Sleep 3
$disk=$v|Get-Disk
$wp=Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root="$((($wp|Get-Volume).DriveLetter)):"
foreach($f in 'C:\NetGuard\result.txt'){
  $p=$root + ($f -replace '^C:','')
  L "--- $p ---"
  if(Test-Path $p){ Get-Content $p -Encoding Default | ForEach-Object { L "  $_" } } else { L "  (缺失)" }
}
L "--- C:\NetGuard 内容 ---"
Get-ChildItem "$root\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }
L "--- C:\ProgramData\NetGuard ---"
Get-ChildItem "$root\ProgramData\NetGuard" -ErrorAction SilentlyContinue | ForEach-Object { L "  $($_.Name) $($_.Length)" }
[GC]::Collect(); Dismount-VHD -Path $vhd; L 完成
