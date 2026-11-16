$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-crash5.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 崩溃模块定位 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WC5 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"

Copy-Item "$RepoRoot\build\NetGuardUI.exe" "$ng\NGUI10.exe" -Force
L "已投放 NGUI10.exe"

$ps = @'
$ErrorActionPreference = 'SilentlyContinue'
$out = 'C:\NetGuard\evt.txt'
"=== eventlog errors ===" | Out-File $out -Encoding UTF8
Get-EventLog -LogName Application -EntryType Error -Newest 4 |
    ForEach-Object { "----`r`nTime: $($_.TimeGenerated)`r`nSource: $($_.Source)`r`nEventID: $($_.EventID)`r`nMessage: $($_.Message)" } |
    Out-File $out -Append -Encoding UTF8
"=== WER reports ===" | Out-File $out -Append -Encoding UTF8
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' -Recurse -Filter '*.txt' -ErrorAction SilentlyContinue |
    Select-Object -First 3 | ForEach-Object { "---- $($_.FullName)"; Get-Content $_.FullName -TotalCount 30 } |
    Out-File $out -Append -Encoding UTF8
Get-ChildItem 'C:\Users\freeze\AppData\Local\Microsoft\Windows\WER\ReportArchive' -Recurse -Filter '*.txt' -ErrorAction SilentlyContinue |
    Select-Object -First 3 | ForEach-Object { "---- $($_.FullName)"; Get-Content $_.FullName -TotalCount 30 } |
    Out-File $out -Append -Encoding UTF8
'@
[IO.File]::WriteAllText("$ng\dump-evt.ps1", $ps, (New-Object Text.UTF8Encoding($true)))

$cmd = @'
@echo off
cd /d C:\NetGuard
schtasks /create /tn NgUi10 /tr "C:\NetGuard\NGUI10.exe" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f >nul 2>&1
schtasks /run /tn NgUi10 >nul 2>&1
start "" /b cmd /c "ping -n 45 127.0.0.1 >nul & powershell -NoProfile -ExecutionPolicy Bypass -File C:\NetGuard\dump-evt.ps1"
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgEvt /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\crash5.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\evt.txt" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\CW75' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\CW75\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\CW75\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgEvt -Value 'C:\NetGuard\crash5.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\CW75' 2>&1 | Out-Null
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
    [WC5]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WC5]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WC5]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 1200
    [System.Windows.Forms.SendKeys]::SendWait('1')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    L "已输入 1 + Enter，等待崩溃 + 日志导出"
}
Start-Sleep -Seconds 75
Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- evt.txt ---"
if (Test-Path "$root\NetGuard\evt.txt") { Get-Content "$root\NetGuard\evt.txt" -Encoding UTF8 | Select-Object -First 45 | ForEach-Object { L "  $_" } }
else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
