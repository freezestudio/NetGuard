$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-rebuild2.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 继续重建 Win7（挂盘/挂 ISO/开机）($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$iso    = "$VmsRoot\iso-rebuild\cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso"
$ansVhd = "$VmsRoot\$vmName\answer.vhdx"

$vm = Get-VM -Name $vmName -ErrorAction Stop
L "VM 状态: $($vm.State)"
L "--- 当前设备 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation)  $($_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation)  $($_.Path)" }
Get-VMNetworkAdapter -VMName $vmName | ForEach-Object { L "  NIC $($_.Name) switch=$($_.SwitchName) legacy=$($_.IsLegacy)" }

# 挂应答盘
$attached = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -eq $ansVhd })
if (-not $attached) {
    try {
        Add-VMHardDiskDrive -VMName $vmName -ControllerType IDE -ControllerNumber 1 -ControllerLocation 0 -Path $ansVhd -ErrorAction Stop
        L "应答盘已挂到 IDE 1:0"
    } catch { L "挂应答盘失败: $($_.Exception.Message)" }
} else { L "应答盘已在: $($attached.ControllerType)$($attached.ControllerNumber):$($attached.ControllerLocation)" }

# 挂 ISO
try {
    $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1
    if (-not $dvd) { Add-VMDvdDrive -VMName $vmName -ControllerNumber 0 -ControllerLocation 1; $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1 }
    Set-VMDvdDrive -VMName $vmName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $iso -ErrorAction Stop
    L "ISO 已挂到 DVD $($dvd.ControllerNumber):$($dvd.ControllerLocation)"
} catch { L "挂 ISO 失败: $($_.Exception.Message)" }

try {
    Set-VMBios -VMName $vmName -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy') -ErrorAction Stop
    L "启动顺序: CD, IDE, LegacyNet, Floppy"
} catch { L "设置启动顺序失败: $($_.Exception.Message)" }

L "--- 最终设备 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation)  $($_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation)  $($_.Path)" }

try {
    Start-VM -Name $vmName -ErrorAction Stop
    Start-Sleep -Seconds 12
    L "VM 状态: $((Get-VM -Name $vmName).State)"
} catch { L "启动失败: $($_.Exception.Message)" }
L "完成"
