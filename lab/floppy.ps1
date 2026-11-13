$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\floppy.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 改用虚拟软驱提供应答文件 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vmDir  = "C:\VMs\$vmName"
$vfd    = "$vmDir\answer.vfd"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6; L "已关机" }

# 1) 从应答 VHD 里取出 autounattend.xml（先复制到临时文件）
$ansVhd = "$vmDir\answer.vhdx"
$tmpXml = 'C:\src\NetGuard\lab\autounattend-win7.xml'
if (Test-Path $ansVhd) {
    $v = Mount-VHD -Path $ansVhd -Passthru
    Start-Sleep 2
    $d = ($v | Get-Disk)
    $dl = (Get-Partition -DiskNumber $d.Number | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1).DriveLetter
    if ($dl -and (Test-Path "$($dl):\autounattend.xml")) {
        Copy-Item "$($dl):\autounattend.xml" $tmpXml -Force
        L "已从应答盘取出 autounattend.xml ($((Get-Item $tmpXml).Length) 字节)"
    }
    [GC]::Collect()
    Dismount-VHD -Path $ansVhd
    # 摘下应答 VHD 设备
    Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -eq $ansVhd } | ForEach-Object {
        Remove-VMHardDiskDrive -VMHardDiskDrive $_
        L "已摘除应答硬盘"
    }
}
if (-not (Test-Path $tmpXml)) { L "找不到 autounattend.xml 源，退出"; exit 1 }

# 2) 造虚拟软盘并用 Mount-DiskImage 写入
Remove-Item $vfd -Force -ErrorAction SilentlyContinue
New-VFD -Path $vfd | Out-Null
L "已创建 VFD: $vfd"

$img = $null
try {
    $img = Mount-DiskImage -ImagePath $vfd -Passthru -ErrorAction Stop
    Start-Sleep 2
    $d = ($img | Get-Disk)
    $parts = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue
    $letter = $null
    if ($parts) {
        $vol = $parts | Get-Volume -ErrorAction SilentlyContinue
        $letter = ($vol | Where-Object { $_.DriveLetter } | Select-Object -First 1).DriveLetter
        if (-not $letter -and $vol) {
            # 未格式化：格式化为 FAT
            try {
                Format-Volume -Partition (Get-Partition -DiskNumber $d.Number -PartitionNumber $parts[0].PartitionNumber) `
                              -FileSystem FAT -NewFileSystemLabel ANSWER -Confirm:$false -ErrorAction Stop | Out-Null
                $letter = ((Get-Partition -DiskNumber $d.Number | Get-Volume) | Where-Object { $_.DriveLetter } | Select-Object -First 1).DriveLetter
                L "软盘已格式化 FAT"
            } catch { L "格式化软盘失败: $($_.Exception.Message)" }
        }
    }
    L "软盘盘符: $(if ($letter) { "$letter`:" } else { '(无)' })"
    if ($letter) {
        Copy-Item $tmpXml "$($letter):\autounattend.xml" -Force
        L "已写入 $($letter):\autounattend.xml"
        Get-ChildItem "$($letter):\" -Force | ForEach-Object { L "  内容: $($_.Name) $($_.Length)" }
    }
} catch { L "挂载 VFD 失败: $($_.Exception.Message)" }
if ($img) { [GC]::Collect(); Dismount-DiskImage -ImagePath $vfd -ErrorAction SilentlyContinue }
L "VFD 已卸载"

# 3) 挂到虚拟机软驱
try {
    Set-VMFloppyDiskDrive -VMName $vmName -Path $vfd -ErrorAction Stop
    L "VFD 已挂到虚拟机软驱"
} catch { L "挂载软驱失败: $($_.Exception.Message)" }

# 4) 确认设备并启动
L "--- 设备清单 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }
$fl = Get-VMFloppyDiskDrive -VMName $vmName
L "  Floppy $($fl.Path)"
Set-VMBios -VMName $vmName -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy')

Start-VM -Name $vmName
L "已启动（应答文件在 A:，Setup 应自动接管）"
