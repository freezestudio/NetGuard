$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-crash2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 真实复现崩溃 + 抓事件日志 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WCR {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@

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

Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NGUI7.exe" -Force
L "已投放 NGUI7.exe"

$cmd = @'
@echo off
cd /d C:\NetGuard
rem 交互会话里启动 UI（会弹口令框）
schtasks /create /tn NgUi7 /tr "C:\NetGuard\NGUI7.exe" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f >nul 2>&1
schtasks /run /tn NgUi7 >nul 2>&1
rem 崩溃后（若有）把事件日志导出到 cd2.txt
start "" /b cmd /c "ping -n 75 127.0.0.1 >nul & echo ==== events > C:\NetGuard\cd2.txt & wevtutil qe Application /c:4 /rd:true /f:text /q:\"*[System[(EventID=1000)]]\" >> C:\NetGuard\cd2.txt 2>&1 & tasklist /fi \"imagename eq NGUI7.exe\" >> C:\NetGuard\cd2.txt 2>&1"
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgCrash2 /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\crash2.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\cd2.txt" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\CW72' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\CW72\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\CW72\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgCrash2 -Value 'C:\NetGuard\crash2.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\CW72' 2>&1 | Out-Null
}
[GC]::Collect()
Dismount-VHD -Path $vhd

# 关掉旧 VMConnect，开一个
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep 2
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force

Start-VM -Name $vmName
L "开机等待 100 秒（登录 + 弹出对话框）"
Start-Sleep -Seconds 100
Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
Start-Sleep -Seconds 12

$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($vc) {
    [WCR]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WCR]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WCR]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 1200
    L "输入口令 1 并回车"
    [System.Windows.Forms.SendKeys]::SendWait('1')
    Start-Sleep -Milliseconds 800
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Seconds 8
    # 截图看是否崩溃
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WR2 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
    $r = New-Object WR2+RECT
    [void][WR2]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $bmp.Save('C:\src\NetGuard\lab\win7-after-pw.png', [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "已截图 win7-after-pw.png"
}
L "等待客户机导出事件日志（60 秒）"
Start-Sleep -Seconds 60
Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- cd2.txt ---"
if (Test-Path "$root\NetGuard\cd2.txt") { Get-Content "$root\NetGuard\cd2.txt" -Encoding Default | Select-Object -First 40 | ForEach-Object { L "  $_" } }
else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
