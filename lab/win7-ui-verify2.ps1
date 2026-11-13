$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-ui-verify2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 界面截图（清理重复会话后）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WX {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$vmName = 'Win7-Pro-x64'

# 1) 关掉所有 VMConnect（避免多个会话抢控制台）
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object {
    L "关闭 vmconnect pid=$($_.Id)"
    $_.CloseMainWindow() | Out-Null
}
Start-Sleep 4
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

# 2) 启动虚拟机（若已关）
$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Running') { Start-VM -Name $vmName; L "已开机"; Start-Sleep 90 }
else { L "VM 已在运行" }

# 3) 只开一个连接
Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
Start-Sleep 12

$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $vc) { L "无 VMConnect 窗口"; exit 1 }
[WX]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
[WX]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
[WX]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 1500

$r = New-Object WX+RECT
[void][WX]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\src\NetGuard\lab\win7-ui2.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
L "已截图 win7-ui2.png (${w}x${h})"
L "完成"
