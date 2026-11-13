$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-final-check.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 最终验证（口令后是否进主界面）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WF {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$vmName = 'Win7-Pro-x64'
$vhd    = "C:\VMs\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -eq 'Off') { Start-VM -Name $vmName; L "已开机"; Start-Sleep 95 } else { L "VM 已在运行" }

Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep 2
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force

# 用已装好的交互任务启动 UI（NGUI10 = 修复版，已在客户机里）
Start-Process powershell -ArgumentList 'Start-Sleep 1' -WindowStyle Hidden
$r = @'
schtasks /run /tn NgUi10
'@
# 通过 VMConnect 打开窗口后手动触发不了，改为先看当前桌面状态
Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
Start-Sleep -Seconds 12
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $vc) { L "无 VMConnect"; exit 1 }
[WF]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
[WF]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
[WF]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 1500

function Snap($tag) {
    $r = New-Object WF+RECT
    [void][WF]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $bmp.Save("C:\src\NetGuard\lab\w7v-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "截图 w7v-$tag.png"
}

Snap 'before'
L "输入口令 1 + 回车"
[System.Windows.Forms.SendKeys]::SendWait('1')
Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 6
Snap 'after'
L "完成（对比 before/after 两张图）"
