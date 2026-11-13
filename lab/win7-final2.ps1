$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-final2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 最终验证 v2 $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WG3 {
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
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"
$pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null

# 必须投当前 build，否则会运行客户机里旧的 UI（旧 UI 的口令框回车/确定无效）
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NGUI10.exe" -Force
Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NetGuardUI.exe" -Force
if (-not (Test-Path "$pd\admin.dat")) {
    Copy-Item 'C:\src\NetGuard\lab\admin.dat' "$pd\admin.dat" -Force
}
L "已投放 NGUI10.exe ($((Get-Item "$ng\NGUI10.exe").Length) 字节)"

$cmd = @'
@echo off
cd /d C:\NetGuard
schtasks /create /tn NgFinal /tr "C:\NetGuard\NGUI10.exe" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f >nul 2>&1
schtasks /run /tn NgFinal >nul 2>&1
start "" /b cmd /c "ping -n 90 127.0.0.1 >nul & powershell -NoProfile -Command \"Get-EventLog -LogName Application -EntryType Error -Newest 3 | ForEach-Object { \\\"T=$($_.TimeGenerated) ID=$($_.EventID) MSG=$($_.Message)\\\" } | Out-File C:\NetGuard\evt2.txt -Encoding UTF8\""
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgFinal /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\final2.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\evt2.txt" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\FW7' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\FW7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\FW7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgFinal -Value 'C:\NetGuard\final2.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\FW7' 2>&1 | Out-Null
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep 2
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force

Start-VM -Name $vmName
L "开机等待 105 秒（登录 + 任务启动 UI）"
Start-Sleep -Seconds 105
Start-Process vmconnect.exe -ArgumentList 'localhost', $vmName
Start-Sleep -Seconds 12
$vc = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $vc) { L "无 VMConnect"; exit 1 }
[WG3]::ShowWindow($vc.MainWindowHandle, 9) | Out-Null
[WG3]::BringWindowToTop($vc.MainWindowHandle) | Out-Null
[WG3]::SetForegroundWindow($vc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 1500

function Snap($tag) {
    $r = New-Object WG3+RECT
    [void][WG3]::GetWindowRect($vc.MainWindowHandle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $bmp.Save("C:\src\NetGuard\lab\w7f-$tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    L "截图 w7f-$tag.png"
}

Snap '1-dialog'
L "输入口令 1 + 回车"
[System.Windows.Forms.SendKeys]::SendWait('1')
Start-Sleep -Milliseconds 700
[System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
Start-Sleep -Seconds 7
Snap '2-main'

L "等待日志导出（40 秒）"
Start-Sleep -Seconds 40
Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- evt2.txt（最近的应用程序错误）---"
if (Test-Path "$root\NetGuard\evt2.txt") { Get-Content "$root\NetGuard\evt2.txt" -Encoding UTF8 | Select-Object -First 20 | ForEach-Object { L "  $_" } }
else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
