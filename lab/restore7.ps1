$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\restore7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 回滚 Win7 到 patched 快照 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$snaps = Get-VMSnapshot -VMName $vmName
L "现有快照: $(($snaps | ForEach-Object { $_.Name }) -join ', ')"

Restore-VMSnapshot -VMName $vmName -Name 'patched' -Confirm:$false
L "已回滚到 patched"
Start-Sleep -Seconds 3

# 关闭"失败自动启动修复"，避免再进修复循环；同时关闭磁盘检查
$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
$srL = (($parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1) | Get-Volume).DriveLetter
L "系统保留: $($srL):"
& bcdedit /store "$($srL):\Boot\BCD" /set '{default}' recoveryenabled No 2>&1 | ForEach-Object { L "  bcdedit: $_" }
& bcdedit /store "$($srL):\Boot\BCD" /set '{default}' bootstatuspolicy IgnoreAllFailures 2>&1 | ForEach-Object { L "  bcdedit: $_" }
& fsutil dirty query "$($srL):" 2>&1 | ForEach-Object { L "  $_" }
[GC]::Collect()
Dismount-VHD -Path $target
L "磁盘已卸载"

Start-VM -Name $vmName
L "已启动，等待 90 秒"
Start-Sleep -Seconds 90

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$shot = $false
for ($i = 0; $i -lt 3 -and -not $shot; $i++) {
    try {
        $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
        if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
            $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
            $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
            $bmp.UnlockBits($d)
            $bmp.Save("$RepoRoot\lab\restored.png", [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            L "截图成功"
            $shot = $true
        } else { L "缩略图 rv=$($res.ReturnValue)" }
    } catch { L "异常: $($_.Exception.Message)" }
    if (-not $shot) { Start-Sleep 10 }
}
L "完成"
