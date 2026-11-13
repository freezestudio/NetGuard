$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\guest-screen.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== 抓 VMConnect 窗口画面 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WG {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$vmName = 'Win10-Pro-22H2'
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $vc) { L "无 VMConnect"; exit 1 }
[WG]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
[WG]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
[WG]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 1200

$r = New-Object WG+RECT
[void][WG]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
L "窗口区域: $($r.Left),$($r.Top) ${w}x${h}"

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save("$RepoRoot\lab\guest-screen.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
L "已保存 guest-screen.png ($((Get-Item "$RepoRoot\lab\guest-screen.png").Length) 字节)"

# 同时查客户机会话状态
$cred = New-Object System.Management.Automation.PSCredential('freeze', (ConvertTo-SecureString '1' -AsPlainText -Force))
$s = New-PSSession -VMName $vmName -Credential $cred
Invoke-Command -Session $s -ScriptBlock {
    "--- qwinsta ---"
    (& qwinsta) -join "`n"
    "--- explorer 会话 ---"
    (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
    "--- 登录用户 ---"
    (Get-CimInstance Win32_ComputerSystem).UserName
} | ForEach-Object { L "  $_" }
Remove-PSSession $s
L "完成"
