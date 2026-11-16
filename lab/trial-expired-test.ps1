$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = 'C:\VMs'
# 验证“60 天试用到期”行为：到期后不套策略、保持联网、apply 被拒绝
$ErrorActionPreference = 'Continue'
$log = "$RepoRoot\lab\trial-expired-test.log"
function L($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
"=== trial expired test $(Get-Date -Format o) ===" | Set-Content $log -Encoding utf8

$vmName = 'Win7-Pro-x64'
$vhd = "$VmsRoot\$vmName\disk.vhdx"

$vm = Get-VM -Name $vmName
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }
L "VM off"

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L "volume=$root"

# 读取现有部署密钥，伪造 61 天前开始的试用（签名必须正确，否则会被判“被修改”）
$swHive = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\NG7SOFT' $swHive 2>&1 | Out-Null
if (-not $?) { L "SOFTWARE hive load failed"; Dismount-VHD -Path $vhd; exit 1 }
$key = (Get-ItemProperty 'HKLM:\NG7SOFT\NetGuard' -ErrorAction SilentlyContinue).PolicyKey
if (-not $key) { L "PolicyKey missing"; & reg unload 'HKLM\NG7SOFT'; Dismount-VHD -Path $vhd; exit 1 }
$start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 61 * 86400
$data = "trial|$start"
$hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(, [Text.Encoding]::UTF8.GetBytes($key))
$sig = (($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($data)) | ForEach-Object { $_.ToString('X2') }) -join '')
New-ItemProperty -Path 'HKLM:\NG7SOFT\NetGuard' -Name 'TrialStart' -PropertyType QWord -Value ([uint64]$start) -Force | Out-Null
New-ItemProperty -Path 'HKLM:\NG7SOFT\NetGuard' -Name 'TrialSig' -PropertyType String -Value $sig -Force | Out-Null
L "trial start set to $start, sig=$sig"
[gc]::Collect(); Start-Sleep -Milliseconds 900
& reg unload 'HKLM\NG7SOFT' 2>&1 | Out-Null

# 投放程序与测试脚本
$ng = "$root\NetGuard"
New-Item -ItemType Directory -Path $ng -Force | Out-Null
foreach ($f in @('NetGuard.exe', 'NetGuardUI.exe')) { Copy-Item "$RepoRoot\build\$f" "$ng\$f" -Force }
foreach ($f in @('install-netguard.ps1', 'uninstall-netguard.ps1')) { Copy-Item "$RepoRoot\$f" "$ng\$f" -Force }

$gbk = [System.Text.Encoding]::GetEncoding(936)
$cmd = @'
@echo off
chcp 936 >nul
cd /d C:\NetGuard
echo === install === > C:\NetGuard\expired.log
powershell -NoProfile -ExecutionPolicy Bypass -File install-netguard.ps1 >> C:\NetGuard\expired.log 2>&1
echo === trial === >> C:\NetGuard\expired.log
NetGuard.exe trial >> C:\NetGuard\expired.log 2>&1
echo trial_exit=%errorlevel% >> C:\NetGuard\expired.log
echo === status === >> C:\NetGuard\expired.log
NetGuard.exe status >> C:\NetGuard\expired.log 2>&1
echo === ctl status === >> C:\NetGuard\expired.log
NetGuard.exe ctl status >> C:\NetGuard\expired.log 2>&1
echo === apply (expect refused) === >> C:\NetGuard\expired.log
NetGuard.exe apply >> C:\NetGuard\expired.log 2>&1
echo apply_exit=%errorlevel% >> C:\NetGuard\expired.log
echo === sc query === >> C:\NetGuard\expired.log
sc query NetGuard >> C:\NetGuard\expired.log 2>&1
echo === uninstall === >> C:\NetGuard\expired.log
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-netguard.ps1 >> C:\NetGuard\expired.log 2>&1
echo done >> C:\NetGuard\expired.log
shutdown /s /t 15 /f
'@
[IO.File]::WriteAllText("$ng\trial-test.cmd", ($cmd -replace "`r?`n", "`r`n"), $gbk)

$startup = "$root\Users\freeze\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Path $startup -Force | Out-Null
$vbs = @'
CreateObject("WScript.Shell").Run "cmd.exe /c C:\NetGuard\trial-test.cmd", 0, False
'@
[IO.File]::WriteAllText("$startup\NetGuardTrialTest.vbs", ($vbs -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
L "deployed test scripts"

[gc]::Collect()
Dismount-VHD -Path $vhd

Start-VM -Name $vmName
L "VM started; waiting for test + shutdown (max 12 min)"
$off = $false
for ($i = 0; $i -lt 72; $i++) {
    Start-Sleep 10
    $st = (Get-VM -Name $vmName).State
    if ($i % 6 -eq 0) { L "  T+$(($i + 1) * 10)s state=$st" }
    if ($st -eq 'Off') { $off = $true; break }
}
L "off=$off"
if (-not $off) { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
if (Test-Path "$root\NetGuard\expired.log") {
    Copy-Item "$root\NetGuard\expired.log" "$RepoRoot\lab\expired.log" -Force
    L "--- expired.log ---"
    Get-Content "$root\NetGuard\expired.log" -Encoding Default | ForEach-Object { L "  $_" }
} else { L "expired.log missing" }
[gc]::Collect()
Dismount-VHD -Path $vhd
L "DONE"
