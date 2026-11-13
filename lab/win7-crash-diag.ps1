$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\win7-crash-diag.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 崩溃定位 ($(Get-Date -Format o)) ===" | Out-File $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd    = "$VmsRoot\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"

Copy-Item "$RepoRoot\build\NetGuardUI.exe" "$ng\NGUI6.exe" -Force
L "已投放 NGUI6.exe = $((Get-Item "$ng\NGUI6.exe").Length)"
L "admin.dat 存在? $(Test-Path "$pd\admin.dat")"

$cmd = @'
@echo off
cd /d C:\NetGuard
echo ===== Win7 crash diag > cd.txt
echo. >> cd.txt
echo --- 1) selftest --- >> cd.txt
NGUI6.exe --selftest >> cd.txt 2>&1
echo EXIT1=%ERRORLEVEL% >> cd.txt
echo. >> cd.txt
echo --- 2) password mode --- >> cd.txt
NGUI6.exe --password 1 >> cd.txt 2>&1
echo EXIT2=%ERRORLEVEL% >> cd.txt
echo. >> cd.txt
echo --- 3) selftest 后是否有窗口残留 --- >> cd.txt
tasklist /fi "imagename eq NGUI6.exe" >> cd.txt 2>&1
echo. >> cd.txt
echo --- application error events --- >> cd.txt
wevtutil qe Application /c:6 /rd:true /f:text /q:"*[System[(EventID=1000)]]" >> cd.txt 2>&1
echo. >> cd.txt
echo --- ui-selftest.txt --- >> cd.txt
if exist C:\ProgramData\NetGuard\ui-selftest.txt type C:\ProgramData\NetGuard\ui-selftest.txt >> cd.txt
echo. >> cd.txt
echo --- ng.log --- >> cd.txt
if exist C:\ProgramData\NetGuard\ng.log type C:\ProgramData\NetGuard\ng.log >> cd.txt
taskkill /f /im NGUI6.exe >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgCrash /f >nul 2>&1
'@
[IO.File]::WriteAllText("$ng\crash.cmd", ($cmd -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\cd.txt", "$pd\ng.log", "$pd\ui-selftest.txt" -Force -ErrorAction SilentlyContinue

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\CW7' $sw 2>&1 | Out-Null
if ($?) {
    New-Item -Path 'HKLM:\CW7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\CW7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgCrash -Value 'C:\NetGuard\crash.cmd' -Type String
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\CW7' 2>&1 | Out-Null
    L "RunOnce=NgCrash 已设置"
}
[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
L "开机等待 120 秒"
Start-Sleep -Seconds 120
Stop-VM -Name $vmName -TurnOff -Force
Start-Sleep 8

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "--- cd.txt ---"
if (Test-Path "$root\NetGuard\cd.txt") {
    Get-Content "$root\NetGuard\cd.txt" -Encoding Default | Select-Object -First 70 | ForEach-Object { L "  $_" }
} else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
