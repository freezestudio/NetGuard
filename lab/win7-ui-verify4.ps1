$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-ui-verify4.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 界面截图 v3（当前构建）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "C:\VMs\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"
$pd = "$root\ProgramData\NetGuard"

Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NGUI4.exe" -Force
L "已投放 NGUI4.exe = $((Get-Item "$ng\NGUI4.exe").Length) 字节（宿主机同尺寸 $((Get-Item 'C:\src\NetGuard\build\NetGuardUI.exe').Length)）"

$cmd = @'
@echo off
taskkill /f /im NGUI2.exe >nul 2>&1
taskkill /f /im NGUI3.exe >nul 2>&1
taskkill /f /im NGUI_test.exe >nul 2>&1
cd /d C:\NetGuard
start "" NGUI4.exe
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgUi5 /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\ui-verify4.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\VW74' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\VW74\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\VW74\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgUi5 -Value 'C:\NetGuard\ui-verify4.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\VW74' 2>&1 | Out-Null
    L "RunOnce=NgUi5 已设置"
}
[GC]::Collect()
Dismount-VHD -Path $vhd

# 关掉所有旧 VMConnect
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep 3
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2

Start-VM -Name $vmName
L "开机等待 110 秒"
Start-Sleep -Seconds 110
Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
Start-Sleep -Seconds 12

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WY {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($vc) {
    [WY]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WY]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WY]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 1500
    $r = New-Object WY+RECT
    [void][WY]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $bmp.Save('C:\src\NetGuard\lab\win7-ui4.png', [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "已截图 win7-ui4.png (${w}x${h})"
}
L "完成"
