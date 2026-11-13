$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-step.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 分步驱动 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W6 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@
$vmName = 'Win7-Pro-x64'
$cs  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$vmName'"
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService

function Cap($tag) {
    $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $cs; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
    if ($res.ReturnValue -eq 0 -and $res.ImageData.Length -gt 0) {
        $bmp = New-Object System.Drawing.Bitmap(1024, 768, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $r = New-Object System.Drawing.Rectangle(0, 0, 1024, 768)
        $d = $bmp.LockBits($r, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        [System.Runtime.InteropServices.Marshal]::Copy($res.ImageData, 0, $d.Scan0, $res.ImageData.Length)
        $bmp.UnlockBits($d); $bmp.Save("C:\src\NetGuard\lab\t7-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        L "  截图 t7-$tag.png"
    }
}
function Focus() {
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $vc) { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName; Start-Sleep 12; $vc = Get-Process vmconnect | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
    if ($vc) {
        [W6]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
        [W6]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
        [W6]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 800
    }
}
function Send([string]$k, $desc) { Focus; L "  发送 [$desc]"; [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 1000 }

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Running') { Start-VM -Name $vmName; L "已开机"; Start-Sleep -Seconds 110 } else { L "已在运行" }

Cap '0-desktop'
L "[1] Ctrl+Esc 打开开始菜单"
Send '^{ESC}' 'start'; Start-Sleep 2; Cap '1-start'

L "[2] 输入 cmd"
Send 'cmd' 'cmd'; Start-Sleep 2; Cap '2-typed'

L "[3] 回车"
Send '{ENTER}' 'enter'; Start-Sleep 4; Cap '3-cmdwin'

L "[4] 输入测试命令（分两段，避免过长）"
Send 'cd /d C:\NetGuard' 'cd'; Send '{ENTER}' 'enter'; Start-Sleep 1
Send 'NetGuard.exe test > result.txt 2>&1' 'run'; Send '{ENTER}' 'enter'
Start-Sleep 25; Cap '4-run'

L "完成（看 4 张截图定位问题）"
