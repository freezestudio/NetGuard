$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-crash3.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 崩溃定位（带 ask 埋点）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WC3 {
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
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"

Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NGUI8.exe" -Force
Remove-Item "$pd\ng.log" -Force -ErrorAction SilentlyContinue
L "已投放 NGUI8.exe"

$cmd = @'
@echo off
cd /d C:\NetGuard
schtasks /create /tn NgUi8 /tr "C:\NetGuard\NGUI8.exe" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f >nul 2>&1
schtasks /run /tn NgUi8 >nul 2>&1
start "" /b cmd /c "ping -n 60 127.0.0.1 >nul & copy /y C:\ProgramData\NetGuard\ng.log C:\NetGuard\ngcopy.txt >nul 2>&1"
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgCrash3 /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\crash3.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\CW73' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\CW73\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\CW73\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgCrash3 -Value 'C:\NetGuard\crash3.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\CW73' 2>&1 | Out-Null
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep 2
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force

Start-VM -Name $vmName
L "开机等待 100 秒"
Start-Sleep -Seconds 100
Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
Start-Sleep -Seconds 12

$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($vc) {
    [WC3]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WC3]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WC3]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 1200
    [System.Windows.Forms.SendKeys]::SendWait('1')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    L "已输入 1 + Enter"
}
L "等待 70 秒让 ng.log 落盘"
Start-Sleep -Seconds 70
Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- ngcopy.txt（崩溃前的最后几条日志）---"
if (Test-Path "$root\NetGuard\ngcopy.txt") {
    Get-Content "$root\NetGuard\ngcopy.txt" -Encoding UTF8 | Select-Object -Last 20 | ForEach-Object { L "  $_" }
} else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
