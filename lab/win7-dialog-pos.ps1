$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-dialog-pos.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 读取对话框定位日志 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

L "--- ng.log 尾部 ---"
$p = "$root\ProgramData\NetGuard\ng.log"
if (Test-Path $p) { Get-Content $p -Encoding UTF8 | Select-Object -Last 15 | ForEach-Object { L "  $_" } } else { L "  (缺失)" }

L "--- 客户机显示设置（从注册表读分辨率线索）---"
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\RDP7' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\RDP7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $key = "HKLM:\RDP7\ControlSet00$cur\Control\Video"
    Get-ChildItem $key -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object {
        $v = Get-ItemProperty $_.PSPath -Name 'DefaultSettings.BitsPerPel', 'DefaultSettings.XResolution', 'DefaultSettings.YResolution' -ErrorAction SilentlyContinue
        if ($v) { L "  $($_.PSChildName): $($v.'DefaultSettings.XResolution')x$($v.'DefaultSettings.YResolution')" }
    }
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\RDP7' 2>&1 | Out-Null
}
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
