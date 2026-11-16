$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-ui-verify.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 界面可见性验证 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"

Copy-Item "$RepoRoot\build\NetGuardUI.exe" "$ng\NGUI2.exe" -Force
Copy-Item "$RepoRoot\build\NetGuard.exe"   "$ng\NetGuard.exe" -Force
L "已投放 NGUI2.exe（$((Get-Item "$ng\NGUI2.exe").Length) 字节）"

$cmd = @'
@echo off
cd /d C:\NetGuard
echo ===== Win7 UI verify > uid3.txt
echo. >> uid3.txt
echo --- selftest --- >> uid3.txt
NGUI2.exe --selftest >> uid3.txt 2>&1
echo SELFTEST_EXIT=%ERRORLEVEL% >> uid3.txt
echo. >> uid3.txt
echo --- ui-selftest.txt --- >> uid3.txt
if exist C:\ProgramData\NetGuard\ui-selftest.txt type C:\ProgramData\NetGuard\ui-selftest.txt >> uid3.txt
if not exist C:\ProgramData\NetGuard\ui-selftest.txt echo NOT_CREATED >> uid3.txt
echo. >> uid3.txt
echo --- ng.log --- >> uid3.txt
if exist C:\ProgramData\NetGuard\ng.log type C:\ProgramData\NetGuard\ng.log >> uid3.txt
if not exist C:\ProgramData\NetGuard\ng.log echo NO_NGLOG >> uid3.txt
echo. >> uid3.txt
echo --- now start plain UI (should show password dialog) --- >> uid3.txt
start "" NGUI2.exe
ping -n 4 127.0.0.1 > nul
tasklist /fi "imagename eq NGUI2.exe" >> uid3.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgUi3 /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\ui-verify.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\uid3.txt", "$pd\ui-selftest.txt" -Force -ErrorAction SilentlyContinue

$pd = "$root\ProgramData\NetGuard"
Remove-Item "$pd\ui-selftest.txt", "$pd\ng.log" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\VW7' $sw 2>&1 | Out-Null
if ($?) {
    Set-ItemProperty 'HKLM:\VW7\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -Type DWord
    New-Item -Path 'HKLM:\VW7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\VW7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgUi3 -Value 'C:\NetGuard\ui-verify.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\VW7' 2>&1 | Out-Null
    L "RunOnce=NgUi3 已设置"
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
L "开机，等待 110 秒（自动登录 + 自检 + 启动界面）"
Start-Sleep -Seconds 110

# 打开 VMConnect 并从宿主机截图
try { Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName } catch {}
Start-Sleep -Seconds 10

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WV7 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$vmName*" -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($vc) {
    [WV7]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
    [WV7]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
    [WV7]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 1500
    $r = New-Object WV7+RECT
    [void][WV7]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $bmp.Save("$RepoRoot\lab\win7-ui.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "已截图 win7-ui.png (${w}x${h})"
} else { L "!! 无 Win7 VMConnect 窗口" }

# 关闭虚拟机并回读 uid3.txt
Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- uid3.txt ---"
if (Test-Path "$root\NetGuard\uid3.txt") { Get-Content "$root\NetGuard\uid3.txt" -Encoding Default | ForEach-Object { L "  $_" } }
else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
