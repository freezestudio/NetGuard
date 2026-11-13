$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\ui-test2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 管理界面：输入口令 + 客户机内截屏 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WU {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@

$vmName = 'Win10-Pro-22H2'

# 1) 聚焦 Win10 的 VMConnect 窗口并输入口令
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($vc) {
    [WU]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WU]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WU]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 800
    L "已聚焦 VMConnect: $($vc.MainWindowTitle)"
    [System.Windows.Forms.SendKeys]::SendWait('1')
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    L "已输入 1 + Enter"
} else { L "!! 没找到 Win10 的 VMConnect 窗口" }
Start-Sleep -Seconds 3

# 2) 客户机内截屏
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred
$r = Invoke-Command -Session $s -ScriptBlock {
    $out = 'C:\NetGuard\screen.png'
    Remove-Item $out -ErrorAction SilentlyContinue
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        "shot ok size=$($vs.Width)x$($vs.Height)"
    } catch { "shot failed: $($_.Exception.Message)" }
    Get-Process NetGuardUI -ErrorAction SilentlyContinue | Select-Object Id, MainWindowTitle
}
$r | ForEach-Object { L "  $_" }

# 3) 取回截图
try {
    Copy-Item -FromSession $s -Path 'C:\NetGuard\screen.png' -Destination 'C:\src\NetGuard\lab\ui-guest.png' -Force
    L "已取回截图: $((Get-Item 'C:\src\NetGuard\lab\ui-guest.png').Length) 字节"
} catch { L "取回失败: $($_.Exception.Message)" }
Remove-PSSession $s
L "完成"
