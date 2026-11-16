$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\setup7-1.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 Setup 键盘驱动 步骤1 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vmDir  = "$VmsRoot\$vmName"
$iso    = "$VmsRoot\iso-rebuild\cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

# 干净的空磁盘（Setup 自动分区，引导由 Setup 自己写）
foreach ($d in Get-VMHardDiskDrive -VMName $vmName) { Remove-VMHardDiskDrive -VMHardDiskDrive $d }
Get-ChildItem $vmDir -Filter '*.vhdx' -ErrorAction SilentlyContinue | Remove-Item -Force
$vhd = "$vmDir\disk.vhdx"
New-VHD -Path $vhd -SizeBytes 60GB -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $vmName -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $vhd
L "空磁盘已创建: 60GB (IDE 0:0)"

# 光驱
$dvds = Get-VMDvdDrive -VMName $vmName
if (-not ($dvds | Where-Object { $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 1 })) {
    Add-VMDvdDrive -VMName $vmName -ControllerNumber 0 -ControllerLocation 1
}
foreach ($d in Get-VMDvdDrive -VMName $vmName) {
    if ($d.ControllerNumber -ne 0 -or $d.ControllerLocation -ne 1) {
        Remove-VMDvdDrive -VMName $vmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -ErrorAction SilentlyContinue
    }
}
Set-VMDvdDrive -VMName $vmName -ControllerNumber 0 -ControllerLocation 1 -Path $iso
try { Set-VMFloppyDiskDrive -VMName $vmName -Path $null } catch {}
Set-VMBios -VMName $vmName -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy')

L "--- 设备 ---"
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }

Start-VM -Name $vmName
L "已启动，等待 80 秒到语言界面"
Start-Sleep -Seconds 80

# 检查键盘对象
$cs = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$kbd = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard
L "键盘对象: $(if ($kbd) { 'OK' } else { '未找到' })"
if ($kbd) {
    $methods = Invoke-CimMethod -InputObject $kbd -MethodName GetType -ErrorAction SilentlyContinue
    try { ($kbd.CimClass.CimClassMethods | Select-Object Name, @{n='Params';e={($_.Parameters | ForEach-Object { $_.Name }) -join ',' } } | Out-String) | ForEach-Object { L "  $_" } } catch {}
}

# 截图
Add-Type -AssemblyName System.Drawing
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
try {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
        $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d)
        $bmp.Save("$RepoRoot\lab\s1.png", [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        L "截图 s1.png"
    } else { L "缩略图 rv=$($res.ReturnValue)" }
} catch { L "截图异常: $($_.Exception.Message)" }
L "完成"
