$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\repair7.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 引导重建 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

# 1) 删除全部快照（合并到基础盘）
$snaps = Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue
L "快照: $(($snaps | ForEach-Object { $_.Name }) -join ', ')"
foreach ($s in $snaps) { Remove-VMSnapshot -VMName $vmName -Name $s.Name -Confirm:$false -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 5
$left = Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue
L "剩余快照: $(if ($left) { ($left | ForEach-Object { $_.Name }) -join ', ' } else { '(无)' })"

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
L "当前磁盘: $target"

# 2) 挂载并重建引导
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
$srPart  = $parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1
$winPart = $parts | Sort-Object Size -Descending | Select-Object -First 1
$srL  = ($srPart  | Get-Volume).DriveLetter
$winL = ($winPart | Get-Volume).DriveLetter
L "系统保留=$($srL):  Windows=$($winL):"

# 分区标记为活动（BIOS 引导必需）
try {
    Set-Partition -DiskNumber $disk.Number -PartitionNumber $srPart.PartitionNumber -IsActive $true -ErrorAction SilentlyContinue
    L "已确保系统保留分区为活动"
} catch { L "设置活动分区失败: $($_.Exception.Message)" }

# chkdsk 两个卷
foreach ($d in @($srL, $winL)) {
    L "--- chkdsk $($d): /f ---"
    & chkdsk "$($d):" /f 2>&1 | Select-Object -Last 3 | ForEach-Object { L "  $_" }
}

# 用客户机自带 bcdboot 重建（BIOS 引导）
$guestBcd = "$($winL):\Windows\System32\bcdboot.exe"
L "客户机 bcdboot 存在: $(Test-Path $guestBcd)  版本: $((Get-Item $guestBcd -ErrorAction SilentlyContinue).VersionInfo.FileVersion)"
if (Test-Path $guestBcd) {
    & $guestBcd "$($winL):\Windows" /s "$($srL):" /l zh-CN 2>&1 | ForEach-Object { L "  bcdboot: $_" }
    L "bcdboot 退出码: $LASTEXITCODE"
}

L "--- 引导文件核对 ---"
foreach ($f in "$($srL):\bootmgr", "$($srL):\Boot\BCD", "$($winL):\Windows\System32\winload.exe") {
    L "  $(Test-Path $f)  $f"
}

# 关闭启动修复循环
& bcdedit /store "$($srL):\Boot\BCD" /set '{default}' recoveryenabled No 2>&1 | ForEach-Object { L "  bcdedit: $_" }
& bcdedit /store "$($srL):\Boot\BCD" /set '{default}' bootstatuspolicy IgnoreAllFailures 2>&1 | ForEach-Object { L "  bcdedit: $_" }
(& bcdedit /store "$($srL):\Boot\BCD" /enum 2>&1) | Select-String 'description|device|path|timeout' | ForEach-Object { L "  $_" }

[GC]::Collect()
Dismount-VHD -Path $target
L "已卸载，启动 VM"

Start-VM -Name $vmName
Start-Sleep -Seconds 75

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
for ($i = 0; $i -lt 3; $i++) {
    try {
        $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
        if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
            $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
            $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
            $bmp.UnlockBits($d)
            $bmp.Save('C:\src\NetGuard\lab\repaired.png', [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose(); L "截图 ok"; break
        } else { L "缩略图 rv=$($res.ReturnValue)" }
    } catch { L "截图异常: $($_.Exception.Message)" }
    Start-Sleep 8
}
L "完成"
