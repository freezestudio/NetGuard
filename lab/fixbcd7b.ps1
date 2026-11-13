$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\fixbcd7b.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 补 {bootmgr} path 并测试引导 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 }

$target = (Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -match 'disk' } | Select-Object -First 1).Path
$v = Mount-VHD -Path $target -Passthru
Start-Sleep -Seconds 3
$disk = $v | Get-Disk
$parts = Get-Partition -DiskNumber $disk.Number
$srL  = (($parts | Where-Object { $_.Size -lt 200MB } | Select-Object -First 1) | Get-Volume).DriveLetter
$winL = (($parts | Sort-Object Size -Descending | Select-Object -First 1) | Get-Volume).DriveLetter
$bcd = "$($srL):\Boot\BCD"
L "系统保留=$($srL): Windows=$($winL):"

# 关键修复：BIOS 引导的 {bootmgr} 需要 path \bootmgr
& bcdedit /store $bcd /set '{bootmgr}' path '\bootmgr' 2>&1 | ForEach-Object { L "  set path: $_" }
# 显式重设两个 device（用宿主可见盘符，bcdedit 会存成分区签名+偏移）
& bcdedit /store $bcd /set '{bootmgr}' device ('partition=' + $srL + ':') 2>&1 | ForEach-Object { L "  bootmgr device: $_" }
& bcdedit /store $bcd /set '{default}' device ('partition=' + $winL + ':') 2>&1 | ForEach-Object { L "  default device: $_" }
& bcdedit /store $bcd /set '{default}' osdevice ('partition=' + $winL + ':') 2>&1 | ForEach-Object { L "  default osdevice: $_" }

# boot.sdi 缺失时补上（从 Recovery 目录复制，便于以后修）
$sdiSrc = Get-ChildItem "$($winL):\Recovery" -Recurse -Filter 'boot.sdi' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sdiSrc -and -not (Test-Path "$($srL):\Boot\boot.sdi")) {
    Copy-Item $sdiSrc.FullName "$($srL):\Boot\boot.sdi" -Force
    L "已补 boot.sdi"
}

L "--- 修复后 ---"
(& bcdedit /store $bcd /enum 2>&1) | ForEach-Object { L "  $_" }

[GC]::Collect()
Dismount-VHD -Path $target
Start-VM -Name $vmName
L "已启动，等待 80 秒后截图"
Start-Sleep -Seconds 80

Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
try {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rect = New-Object System.Drawing.Rectangle(0, 0, 800, 600)
        $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d)
        $bmp.Save('C:\src\NetGuard\lab\fixed2.png', [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose(); L "截图 ok"
    } else { L "缩略图 rv=$($res.ReturnValue)" }
} catch { L "截图异常: $($_.Exception.Message)" }
L "完成"
