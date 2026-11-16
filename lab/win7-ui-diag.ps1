$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-ui-diag.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 UI 启动诊断 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"
$hostUi = "$RepoRoot\build\NetGuardUI.exe"
$hostNg = "$RepoRoot\build\NetGuard.exe"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8; L "已关机" }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null

# 投放：用新文件名，避免旧文件占用
Copy-Item $hostUi "$ng\NGUI_test.exe" -Force
Copy-Item $hostNg "$ng\NetGuard.exe" -Force
L "已投放 NGUI_test.exe（$((Get-Item "$ng\NGUI_test.exe").Length) 字节）"

$cmd = @'
@echo off
cd /d C:\NetGuard
echo ===== Win7 UI diag > uid.txt
ver >> uid.txt
echo. >> uid.txt
echo --- run --selftest --- >> uid.txt
NGUI_test.exe --selftest >> uid.txt 2>&1
echo EXIT=%ERRORLEVEL% >> uid.txt
echo. >> uid.txt
echo --- ui-selftest.txt --- >> uid.txt
if exist C:\ProgramData\NetGuard\ui-selftest.txt (type C:\ProgramData\NetGuard\ui-selftest.txt) else (echo (not created)) >> uid.txt
echo. >> uid.txt
echo --- ng.log --- >> uid.txt
type C:\ProgramData\NetGuard\ng.log >> uid.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgUi /f >nul 2>&1
shutdown /s /t 20 /f
'@
[IO.File]::WriteAllText("$ng\ui-diag.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\uid.txt" -Force -ErrorAction SilentlyContinue
Remove-Item "$pd\ng.log", "$pd\ui-selftest.txt" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\UW7' $sw 2>&1 | Out-Null
if ($?) {
    Set-ItemProperty 'HKLM:\UW7\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -Type DWord
    New-Item -Path 'HKLM:\UW7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\UW7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgUi -Value 'C:\NetGuard\ui-diag.cmd' -Type String
    L "RunOnce=NgUi 已设置"
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\UW7' 2>&1 | Out-Null
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
L "开机，等待 180 秒（登录+自检+关机）"
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep 10
    if ((Get-VM -Name $vmName).State -eq 'Off') { L "已自行关机 (T+$($i*10)s)"; break }
}
if ((Get-VM -Name $vmName).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- uid.txt ---"
if (Test-Path "$root\NetGuard\uid.txt") { Get-Content "$root\NetGuard\uid.txt" -Encoding Default | ForEach-Object { L "  $_" } }
else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
