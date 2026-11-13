$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-main-shot.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 主窗口截图（交互会话）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

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

Copy-Item 'C:\src\NetGuard\build\NetGuardUI.exe' "$ng\NGUI5.exe" -Force
L "已投放 NGUI5.exe = $((Get-Item "$ng\NGUI5.exe").Length)"

$cmd = @'
@echo off
taskkill /f /im NGUI3.exe >nul 2>&1
taskkill /f /im NGUI4.exe >nul 2>&1
cd /d C:\NetGuard
schtasks /create /tn NgShot /tr "'C:\NetGuard\NGUI5.exe' --screenshot C:\NetGuard\uiw7.bmp" /sc once /st 00:00 /ru freeze /rp 1 /rl HIGHEST /it /f >nul 2>&1
schtasks /run /tn NgShot >nul 2>&1
ping -n 20 127.0.0.1 > nul
echo ==== result >> C:\NetGuard\shot.txt
if exist C:\NetGuard\uiw7.bmp (echo BMP_OK) else (echo BMP_MISSING) >> C:\NetGuard\shot.txt
if exist C:\ProgramData\NetGuard\ng.log type C:\ProgramData\NetGuard\ng.log >> C:\NetGuard\shot.txt
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgShot6 /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\w7shot.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\shot.txt", "$ng\uiw7.bmp" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\SW7' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\SW7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SW7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgShot6 -Value 'C:\NetGuard\w7shot.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\SW7' 2>&1 | Out-Null
    L "RunOnce=NgShot6 已设置"
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
L "开机等待 130 秒（登录 + 任务运行 + 截图）"
Start-Sleep -Seconds 130

Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

L "--- shot.txt ---"
if (Test-Path "$root\NetGuard\shot.txt") { Get-Content "$root\NetGuard\shot.txt" -Encoding Default | Select-Object -Last 12 | ForEach-Object { L "  $_" } } else { L "  (缺失)" }

if (Test-Path "$root\NetGuard\uiw7.bmp") {
    Copy-Item "$root\NetGuard\uiw7.bmp" 'C:\src\NetGuard\lab\uiw7.bmp' -Force
    L "已取回 uiw7.bmp（$((Get-Item 'C:\src\NetGuard\lab\uiw7.bmp').Length) 字节）"
} else { L "uiw7.bmp 未生成" }

[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
