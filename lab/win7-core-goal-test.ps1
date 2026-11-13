$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'win7-core-goal-test.log'
$script:fail = 0
$script:checks = @()
function L([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
function Phase([string]$t) { L ''; L ('==== ' + $t + ' ====') }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { L ('PASS  ' + $name + '  ' + $detail) }
    else { L ('FAIL  ' + $name + '  ' + $detail); $script:fail++ }
    $script:checks += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
}
function Note([string]$m) { L ('NOTE  ' + $m) }
'=== NetGuard Win7 core-goal test @ ' + (Get-Date -Format o) + ' ===' | Set-Content -Path $log -Encoding UTF8

$vmName = 'Win7-Pro-x64'
$vhd = "C:\VMs\$vmName\disk.vhdx"

Phase '0. prepare'
# 释放内存：两台 VM 同时开会导致 Win7 极慢
$w10 = Get-VM -Name 'Win10-Pro-22H2' -ErrorAction SilentlyContinue
if ($w10 -and $w10.State -ne 'Off') {
    L 'stopping Win10 VM to free memory'
    Stop-VM -Name 'Win10-Pro-22H2' -TurnOff -Force -ErrorAction SilentlyContinue
    Start-Sleep 8
}
$vm = Get-VM -Name $vmName -ErrorAction Stop
if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }
L ('Win7 state=' + (Get-VM -Name $vmName).State)

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L ('mounted Windows volume as ' + $root)

$ng = "$root\NetGuard"
$pd = "$root\ProgramData\NetGuard"
New-Item -ItemType Directory -Path $ng, $pd -Force | Out-Null
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe' "$ng\NetGuard.exe" -Force
Copy-Item 'C:\src\NetGuard\build\NetGuard.exe' "$ng\ngcopy.exe" -Force
L ('NetGuard.exe deployed: ' + (Get-Item "$ng\NetGuard.exe").Length + ' bytes')

$h = '576D7845CE13FA93E688B98037E56F9A4218FAB3B20FCF5D589ACCAB5C55C40E'
$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=DNS
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[proc.1]
Name=netguard-self
Path=C:\NetGuard\NetGuard.exe
Sha256=$h
Endpoint=DNS
Enable=1
"@
[IO.File]::WriteAllText("$pd\policy.ini", ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
L 'policy.ini deployed (DefaultDeny=1, only NetGuard.exe -> 8.8.8.8:53/TCP)'

$test = @'
@echo off
cd /d C:\NetGuard
echo ===== Win7 core goal test > result.txt
ver >> result.txt
echo --- initkey --- >> result.txt
NetGuard.exe initkey >> result.txt 2>&1
echo initkey_exit=%ERRORLEVEL% >> result.txt
echo --- sign --- >> result.txt
NetGuard.exe sign >> result.txt 2>&1
echo sign_exit=%ERRORLEVEL% >> result.txt
echo --- install --- >> result.txt
NetGuard.exe install >> result.txt 2>&1
echo install_exit=%ERRORLEVEL% >> result.txt
sc start NetGuard >> result.txt 2>&1
echo start_exit=%ERRORLEVEL% >> result.txt
ping -n 6 127.0.0.1 >nul
echo --- ctl apply --- >> result.txt
NetGuard.exe ctl apply >> result.txt 2>&1
echo apply_exit=%ERRORLEVEL% >> result.txt
ping -n 2 127.0.0.1 >nul
echo --- whitelisted NetGuard.exe selftest --- >> result.txt
NetGuard.exe selftest >> result.txt 2>&1
echo wl_exit=%ERRORLEVEL% >> result.txt
echo --- unlisted ngcopy.exe selftest --- >> result.txt
ngcopy.exe selftest >> result.txt 2>&1
echo copy_exit=%ERRORLEVEL% >> result.txt
echo --- ping 8.8.8.8 --- >> result.txt
ping -n 2 -w 1000 8.8.8.8 >> result.txt 2>&1
echo ping_exit=%ERRORLEVEL% >> result.txt
echo --- ctl status --- >> result.txt
NetGuard.exe ctl status >> result.txt 2>&1
echo --- ctl rollback --- >> result.txt
NetGuard.exe ctl rollback >> result.txt 2>&1
sc stop NetGuard >> result.txt 2>&1
echo --- ng.log --- >> result.txt
type C:\ProgramData\NetGuard\ng.log >> result.txt 2>&1
echo --- filters --- >> result.txt
type C:\ProgramData\NetGuard\filters.txt >> result.txt 2>&1
echo --- audit --- >> result.txt
type C:\ProgramData\NetGuard\audit.log >> result.txt 2>&1
shutdown /s /t 20 /f
'@
[IO.File]::WriteAllText("$ng\test.cmd", ($test -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\result.txt" -Force -ErrorAction SilentlyContinue

# 离线注册表：关闭 UAC、自动登录、RunOnce
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\S7' $sysHive 2>&1 | Out-Null
$compName = $null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\S7\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $compName = (Get-ItemProperty "HKLM:\S7\ControlSet00$cur\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\S7' 2>&1 | Out-Null
}
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\W7' $sw 2>&1 | Out-Null
if (-not $?) { throw '无法加载 Win7 SOFTWARE hive' }
$sysPol = 'HKLM:\W7\Microsoft\Windows\CurrentVersion\Policies\System'
New-Item -Path $sysPol -Force | Out-Null
Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
$wl = 'HKLM:\W7\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
if ($compName) { Set-ItemProperty $wl -Name DefaultDomainName -Value $compName -Type String }
Set-ItemProperty $wl -Name ForceAutoLogon -Value '1' -Type String
New-Item -Path 'HKLM:\W7\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
Set-ItemProperty 'HKLM:\W7\Microsoft\Windows\CurrentVersion\RunOnce' -Name NgCore -Value 'C:\NetGuard\test.cmd' -Type String
L ('registry: auto-logon ' + $compName + '\freeze, RunOnce=NgCore')
[gc]::Collect(); Start-Sleep -Milliseconds 900
& reg unload 'HKLM\W7' 2>&1 | Out-Null

[gc]::Collect()
Dismount-VHD -Path $vhd
L 'VHD dismounted; booting Win7'

Start-VM -Name $vmName
for ($i = 0; $i -lt 42; $i++) {
    Start-Sleep 10
    $st = (Get-VM -Name $vmName).State
    if ($i % 3 -eq 0) { L ('  T+' + ($i * 10) + 's state=' + $st) }
    if ($st -eq 'Off') { L 'guest powered off'; break }
}
$st = (Get-VM -Name $vmName).State
if ($st -ne 'Off') { L 'forcing power off'; Stop-VM -Name $vmName -TurnOff -Force; Start-Sleep 8 }

Phase '1. collect Win7 result'
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$res = "$root\NetGuard\result.txt"
if (Test-Path $res) {
    $txt = Get-Content $res -Encoding Default
    $txt | ForEach-Object { L ('  ' + $_) }
    Copy-Item $res (Join-Path $lab 'win7-core-goal-result.txt') -Force
} else {
    L '  result.txt MISSING'
    $txt = @()
}
foreach ($f in @('ng.log','filters.txt','audit.log')) {
    $p = "$root\ProgramData\NetGuard\$f"
    if (Test-Path $p) {
        L ('--- ' + $f + ' ---')
        Get-Content $p -Encoding Default | Select-Object -Last 40 | ForEach-Object { L ('  ' + $_) }
    }
}
[gc]::Collect()
Dismount-VHD -Path $vhd

# ---------------------------------------------------------------- parse
$all = ($txt -join "`n")
$wlSec = ''
$copySec = ''
if ($all -match '(?s)--- whitelisted NetGuard\.exe selftest ---(.*?)--- unlisted ngcopy\.exe selftest ---') { $wlSec = $Matches[1] }
if ($all -match '(?s)--- unlisted ngcopy\.exe selftest ---(.*?)--- ping 8\.8\.8\.8 ---') { $copySec = $Matches[1] }
L ''
L '--- parsed sections ---'
L ('whitelisted: ' + (($wlSec -split "`r?`n" | Where-Object { $_ -match 'LEAK|BLOCK|leaked' }) -join ' | '))
L ('unlisted:    ' + (($copySec -split "`r?`n" | Where-Object { $_ -match 'LEAK|BLOCK|leaked' }) -join ' | '))

$wlLeak = ($wlSec -match '\[LEAK \]\s+8\.8\.8\.8:53')
$copyLeak = ($copySec -match '\[LEAK \]')
$statusMatch = ($all -match 'filters=(\d+)')
$filters = if ($statusMatch) { [int]$Matches[1] } else { -1 }
$pingFail = ($all -match 'ping_exit=[1-9]')

Check 'Win7: whitelisted NetGuard.exe can reach 8.8.8.8:53' $wlLeak ''
Check 'Win7: unlisted copy has 0 leaks' (-not $copyLeak) ''
Check 'Win7: ICMP 8.8.8.8 blocked by policy' $pingFail ''
Check 'Win7: service reports >=6 filters after apply' ($filters -ge 6) ('filters=' + $filters)

Phase 'SUMMARY'
L ("total checks={0} failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
