$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\w7test2.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== Win7 自动测试 v2（含局域网对照目标）$(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$w10 = 'Win10-Pro-22H2'
$w7  = 'Win7-Pro-x64'
$vhd = "$VmsRoot\$w7\disk.vhdx"
$exe = "$RepoRoot\build\NetGuard.exe"

# ---- 1. 确保 Win10 在跑（本地对照目标 172.30.18.120:3389）----
$v10 = Get-VM -Name $w10 -ErrorAction SilentlyContinue
if ($v10 -and $v10.State -ne 'Running') { Start-VM -Name $w10; L "Win10 已启动" }
if ($v10) {
    Start-Sleep 25
    $ips = (Get-VMNetworkAdapter -VMName $w10).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    L "Win10 状态=$((Get-VM -Name $w10).State) IP=$($ips -join ',')"
}

# ---- 2. 关 Win7，部署 ----
$vm = Get-VM -Name $w7 -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $w7 -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"

$ng = "$root\NetGuard"; $pd = "$root\ProgramData\NetGuard"
Copy-Item $exe "$ng\NetGuard.exe" -Force
Remove-Item "$ng\result.txt" -Force -ErrorAction SilentlyContinue
L "新 exe 已投放"

$test = @'
@echo off
cd /d C:\NetGuard
echo ===== NetGuard Win7 test v2 > result.txt
ver >> result.txt
echo. >> result.txt
echo --- ipconfig --- >> result.txt
ipconfig >> result.txt 2>&1
echo. >> result.txt
NetGuard.exe test >> result.txt 2>&1
echo EXITCODE=%ERRORLEVEL% >> result.txt
echo. >> result.txt
echo --- ng.log --- >> result.txt
type C:\ProgramData\NetGuard\ng.log >> result.txt 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgTest /f >nul 2>&1
shutdown /s /t 25 /f
'@
[IO.File]::WriteAllText("$ng\test.cmd", ($test -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))

$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\W7' $sw 2>&1 | Out-Null
if ($?) {
    $sysPol = 'HKLM:\W7\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
    New-Item -Path 'HKLM:\W7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty 'HKLM:\W7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgTest -Value 'C:\NetGuard\test.cmd' -Type String
    L "RunOnce 已设置"
    [gc]::Collect(); Start-Sleep -Milliseconds 900
    & reg unload 'HKLM\W7' 2>&1 | Out-Null
}

[GC]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $w7
L "已开机，等待测试+关机"
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep 10
    $st = (Get-VM -Name $w7).State
    if ($st -eq 'Off') { L "已自动关机 (T+$($i*10)s)"; break }
}
if ((Get-VM -Name $w7).State -ne 'Off') { Stop-VM -Name $w7 -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$res = "$root\NetGuard\result.txt"
L "--- result.txt ---"
if (Test-Path $res) { Get-Content $res -Encoding Default | ForEach-Object { L "  $_" } } else { L "  (缺失)" }
[GC]::Collect()
Dismount-VHD -Path $vhd
L "完成"
