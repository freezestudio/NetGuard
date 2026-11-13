$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-rebuild3.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 修正设备并重启安装 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$iso    = "$VmsRoot\iso-rebuild\cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso"
$ansVhd = "$VmsRoot\$vmName\answer.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已关机" }

L "--- 清理多余光驱 ---"
$dvds = Get-VMDvdDrive -VMName $vmName
L "当前光驱数: $($dvds.Count)"
foreach ($d in $dvds) {
    L "  光驱 $($d.ControllerNumber):$($d.ControllerLocation) path=$($d.Path)"
}
# 只保留 0:1（挂 ISO），删掉其余
$keep = $dvds | Where-Object { $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 1 } | Select-Object -First 1
foreach ($d in $dvds) {
    if ($keep -and $d.ControllerNumber -eq $keep.ControllerNumber -and $d.ControllerLocation -eq $keep.ControllerLocation) { continue }
    try {
        Remove-VMDvdDrive -VMName $vmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -ErrorAction Stop
        L "  已删除光驱 $($d.ControllerNumber):$($d.ControllerLocation)"
    } catch { L "  删除光驱失败 $($d.ControllerNumber):$($d.ControllerLocation): $($_.Exception.Message)" }
}

if (-not $keep) {
    Add-VMDvdDrive -VMName $vmName -ControllerNumber 0 -ControllerLocation 1
    L "已补建光驱 0:1"
}
Set-VMDvdDrive -VMName $vmName -ControllerNumber 0 -ControllerLocation 1 -Path $iso
L "ISO 挂到 0:1"

L "--- 挂应答盘到 IDE 1:0 ---"
try {
    Add-VMHardDiskDrive -VMName $vmName -ControllerType IDE -ControllerNumber 1 -ControllerLocation 0 -Path $ansVhd -ErrorAction Stop
    L "  应答盘已挂载"
} catch { L "  失败: $($_.Exception.Message)" }

L "--- 最终设备 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation)  $(Split-Path -Leaf $_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation)  $(Split-Path -Leaf $_.Path)" }
Set-VMBios -VMName $vmName -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy')

Start-VM -Name $vmName
L "已启动，安装中（预计 20-30 分钟）"
