$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\rebuild-vm7.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 重建 Win7 VM 对象（保留 disk.vhdx）($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$dir    = "$VmsRoot\$vmName"
$base   = "$dir\disk.vhdx"
$iso    = "$VmsRoot\iso-rebuild\cn_windows_7_professional_with_sp1_x64_dvd_u_677031.iso"

if (-not (Test-Path $base)) { L "基础盘不存在: $base"; exit 1 }
L ("基础盘: {0:N2} GB" -f ((Get-Item $base).Length/1GB))

$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($vm) {
    if ($vm.State -notin @('Off', 'Saved')) { try { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 6 } catch {} }
    Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
    L "已删除旧 VM 对象"
}
Start-Sleep 3

# 删除孤立 avhdx
Get-ChildItem $dir -Filter '*.avhdx' | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    L "已删除孤立 avhdx: $($_.Name)"
}

# 新建 VM
New-VM -Name $vmName -Generation 1 -MemoryStartupBytes 3GB -VHDPath $base | Out-Null
Set-VMProcessor      $vmName -Count 2
Set-VMMemory         $vmName -DynamicMemoryEnabled $false -StartupBytes 3GB
Add-VMNetworkAdapter $vmName -SwitchName 'Default Switch' -IsLegacy $true
Add-VMDvdDrive       $vmName -ControllerNumber 0 -ControllerLocation 1
Set-VMDvdDrive       $vmName -ControllerNumber 0 -ControllerLocation 1 -Path $iso
Set-VMComPort        $vmName -Path '\\.\pipe\win7dbg' -Number 1
Set-VM               $vmName -AutomaticStopAction ShutDown -AutomaticStartAction Nothing `
                     -AutomaticCheckpointsEnabled $false
Get-VMNetworkAdapter -VMName $vmName | Where-Object { -not $_.IsLegacy } |
    ForEach-Object { Remove-VMNetworkAdapter -VMName $vmName -Name $_.Name }
Set-VMBios -VMName $vmName -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy')
L "新 VM 已创建（自动检查点已关闭）"

Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { L "  HDD $($_.ControllerType)$($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }
Get-VMDvdDrive -VMName $vmName | ForEach-Object { L "  DVD $($_.ControllerNumber):$($_.ControllerLocation) $(Split-Path -Leaf $_.Path)" }

Start-VM -Name $vmName
L "已启动，等待 120 秒观察是否自动登录"
Start-Sleep -Seconds 120

Add-Type -AssemblyName System.Drawing
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
for ($i = 0; $i -lt 3; $i++) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("$RepoRoot\lab\w7-ok.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "截图 w7-ok.png"; break
    } else { L "缩略图 rv=$($res.ReturnValue)"; Start-Sleep 6 }
}
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName; L "已打开 VMConnect" } catch {}
L "VM 状态: $((Get-VM -Name $vmName).State)"
L "完成"
