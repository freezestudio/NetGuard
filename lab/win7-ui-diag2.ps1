$ErrorActionPreference = 'Continue'
$log = 'C:\src\NetGuard\lab\win7-ui-diag2.log'
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 UI 诊断 v2（事件日志）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "C:\VMs\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"

$cmd = @'
@echo off
cd /d C:\NetGuard
echo ===== Win7 UI diag2 > uid2.txt
ver >> uid2.txt
echo. >> uid2.txt
echo --- files --- >> uid2.txt
dir /b >> uid2.txt
echo. >> uid2.txt
echo --- run selftest --- >> uid2.txt
NGUI_test.exe --selftest >> uid2.txt 2>&1
echo SELFTEST_EXIT=%ERRORLEVEL% >> uid2.txt
echo. >> uid2.txt
echo --- run plain (no args) --- >> uid2.txt
start "" NGUI_test.exe
ping -n 4 127.0.0.1 > nul
tasklist /fi "imagename eq NGUI_test.exe" >> uid2.txt 2>&1
echo. >> uid2.txt
echo --- ng.log --- >> uid2.txt
if exist C:\ProgramData\NetGuard\ng.log (type C:\ProgramData\NetGuard\ng.log) else (echo NO_NGLOG) >> uid2.txt
echo. >> uid2.txt
echo --- app event log (Application Error / .NET Runtime) --- >> uid2.txt
wevtutil qe Application /c:12 /rd:true /f:text /q:"*[System[(EventID=1000 or EventID=1001 or EventID=1002)]]" >> uid2.txt 2>&1
echo. >> uid2.txt
echo --- Network/Virtualization deps --- >> uid2.txt
where /r C:\Windows\System32 bcrypt.dll >> uid2.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgUi2 /f >nul 2>&1
shutdown /s /t 20 /f
'@
[IO.File]::WriteAllText("$ng\ui-diag2.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\uid2.txt" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\UW72' $sw 2>&1 | Out-Null
if ($?) {
    Set-ItemProperty 'HKLM:\UW72\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 0 -Type DWord
    New-Item -Path 'HKLM:\UW72\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\UW72\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgUi2 -Value 'C:\NetGuard\ui-diag2.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\UW72' 2>&1 | Out-Null
    L "RunOnce=NgUi2 已设置"
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
L "开机等待 200 秒"
for ($i = 0; $i -lt 26; $i++) {
    Start-Sleep 10
    if ((Get-VM -Name $vmName).State -eq 'Off') { L "已关机 (T+$($i*10)s)"; break }
}
if ((Get-VM -Name $vmName).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- uid2.txt ---"
if (Test-Path "$root\NetGuard\uid2.txt") {
    Get-Content "$root\NetGuard\uid2.txt" -Encoding Default | Select-Object -First 60 | ForEach-Object { L "  $_" }
} else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
