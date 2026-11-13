$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\setup7-4.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 Setup 步骤4（节奏化）($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W3 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@

$vmName = 'Win7-Pro-x64'
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService

function Focus() {
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $vc) { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName; Start-Sleep 12; $vc = Get-Process vmconnect | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
    if ($vc) {
        [W3]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
        [W3]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
        [W3]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 700
    } else { L "  !! 找不到 VMConnect 窗口" }
}
function Key($k, $desc) { Focus; L "  发送 [$desc] $k"; [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 1200 }
function Cap($tag) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("C:\src\NetGuard\lab\q7-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "  截图 q7-$tag.png"
    }
}

# 重启到干净状态
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }
$vhd = 'C:\VMs\Win7-Pro-x64\disk.vhdx'
if (Test-Path $vhd) { Remove-Item $vhd -Force -ErrorAction SilentlyContinue }
Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { Remove-VMHardDiskDrive -VMHardDiskDrive $_ -ErrorAction SilentlyContinue }
New-VHD -Path $vhd -SizeBytes 60GB -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $vmName -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $vhd
L "已重置为空磁盘"
Start-VM -Name $vmName
L "已启动，等待语言界面（90 秒）"
Start-Sleep -Seconds 90

L "[1] 语言界面 → 下一步"
Key '{ENTER}' '语言/下一步'
Start-Sleep -Seconds 45; Cap 'a'

L "[2] 现在安装"
Key '{ENTER}' '现在安装'
Start-Sleep -Seconds 20; Cap 'b'
L "完成（下一步：验收 b 图是否为许可条款界面）"
