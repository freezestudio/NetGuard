$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\chkdsk.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 修复脏位 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
$srPart = $parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1
$winPart = $parts | Sort-Object Size -Descending | Select-Object -First 1
$srL = ($srPart | Get-Volume).DriveLetter
$winL = ($winPart | Get-Volume).DriveLetter
L "系统保留=$($srL):  Windows=$($winL):"

L "--- chkdsk $($srL): /f ---"
& chkdsk "$($srL):" /f 2>&1 | ForEach-Object { L "  $_" }

L "--- chkdsk $($winL): /f （可能较慢，但 E: 本来就干净，只是顺便）---"
& chkdsk "$($winL):" /f 2>&1 | Select-Object -Last 12 | ForEach-Object { L "  $_" }

L "--- 脏位复查 ---"
& fsutil dirty query "$($srL):" 2>&1 | ForEach-Object { L "  $_" }
& fsutil dirty query "$($winL):" 2>&1 | ForEach-Object { L "  $_" }

[GC]::Collect()
Dismount-VHD -Path $target
L "已卸载，启动 VM 验证"
Start-VM -Name $vmName
Start-Sleep -Seconds 45

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
try {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rect = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d)
        $bmp.Save('C:\src\NetGuard\lab\after-fix.png', [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        L "已保存 after-fix.png"
    } else { L "缩略图失败 rv=$($res.ReturnValue)" }
} catch { L "截图异常: $($_.Exception.Message)" }
L "完成"
