$VmsRoot = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WShot11 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like '*Win11-Test*' } | Select-Object -First 1
if (-not $vc) {
    Start-Process vmconnect.exe -ArgumentList 'localhost','Win11-Test'
    Start-Sleep 6
    $vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like '*Win11-Test*' } | Select-Object -First 1
}
if (-not $vc) { 'no vmconnect'; exit 1 }
[WShot11]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
[WShot11]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
[WShot11]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 800
$r = New-Object WShot11+RECT
[void][WShot11]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save("$VmsRoot\iso-rebuild\win11-install.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
'captured ' + $w + 'x' + $h
