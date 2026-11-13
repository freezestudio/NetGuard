$RepoRoot = Split-Path $PSScriptRoot -Parent
$VmsRoot  = Join-Path $RepoRoot 'infra\vms'
$ErrorActionPreference = 'Stop'
$lab = "$RepoRoot\lab"
$log = Join-Path $lab 'win7-drv-test.log'
function L([string]$m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
'=== Win7 ngdrv test ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8

# 签名驱动（使用现有测试证书）
# Win7 需要 SHA-1 测试证书/签名（部分 Win7 对 SHA-256 驱动签名校验失败）
$cert7 = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq 'CN=NetGuardWin7Test' } | Select-Object -First 1
if (-not $cert7) {
    $cert7 = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=NetGuardWin7Test' `
             -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy Exportable -HashAlgorithm sha1
}
$cer7 = Join-Path $lab 'NetGuardWin7Test.cer'
Export-Certificate -Cert $cert7 -FilePath $cer7 -Force | Out-Null
$signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
Copy-Item "$RepoRoot\drv\out\ngdrv.sys" "$RepoRoot\drv\out\ngdrv-win7.sys" -Force
& $signtool sign /fd sha1 /sm /s My /sha1 $cert7.Thumbprint "$RepoRoot\drv\out\ngdrv-win7.sys" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'SHA-1 driver signing failed' }
L ('Win7 driver signed SHA-1, thumbprint=' + $cert7.Thumbprint)

# 关闭两台 VM
foreach ($n in @('Win7-Pro-x64','Win10-Pro-22H2')) {
    $v = Get-VM -Name $n -ErrorAction SilentlyContinue
    if ($v -and $v.State -ne 'Off') { Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue; Start-Sleep 3 }
}
Get-Process mstsc,vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$vhd = "$VmsRoot\Win7-Pro-x64\disk.vhdx"
$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 3
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
L ('Win7 volume=' + $root)

$ng = "$root\NetGuard"
$pd = "$root\ProgramData\NetGuard"
$drv = "$ng\drv"
New-Item -ItemType Directory -Path $drv, $pd -Force | Out-Null
Copy-Item "$RepoRoot\build\NetGuard.exe" "$ng\NetGuard.exe" -Force
Copy-Item "$RepoRoot\build\NetGuardUI.exe" "$ng\NetGuardUI.exe" -Force
Copy-Item "$RepoRoot\build\NetGuard.exe" "$ng\ngblock.exe" -Force
Copy-Item "$RepoRoot\drv\out\ngdrv-win7.sys" "$drv\ngdrv.sys" -Force
Copy-Item $cer7 "$drv\NetGuardTest.cer" -Force
[IO.File]::WriteAllText("$ng\tamper.bin", 'NG-WIN7-DRV-TAMPER', (New-Object Text.ASCIIEncoding))

$h = (& "$RepoRoot\build\NetGuard.exe" hash "$RepoRoot\build\NetGuard.exe").Trim()
L ('ngblock hash=' + $h)

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=DNS
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[proc.1]
Name=ngblock
Path=C:\NetGuard\ngblock.exe
Sha256=$h
Endpoint=DNS
Enable=1
"@
[IO.File]::WriteAllText("$pd\policy.ini", ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))

$test = @'
@echo off
cd /d C:\NetGuard
if exist C:\NetGuard\ts-on.flag goto phase2
echo ===== phase1: enable testsigning > result1.txt
ver >> result1.txt
bcdedit /set testsigning on >> result1.txt 2>&1
bcdedit /set nointegritychecks on >> result1.txt 2>&1
bcdedit /enum "{current}" >> result1.txt 2>&1
echo on > C:\NetGuard\ts-on.flag
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v NgDrvTest2 /t REG_SZ /d "C:\NetGuard\drvtest.cmd" /f >> result1.txt 2>&1
shutdown /r /t 5 /f
exit /b

:phase2
echo ===== Win7 ngdrv test > result.txt
ver >> result.txt
bcdedit /enum "{current}" >> result.txt 2>&1
echo --- cert --- >> result.txt
certutil -addstore -f Root C:\NetGuard\drv\NetGuardTest.cer >> result.txt 2>&1
certutil -addstore -f TrustedPublisher C:\NetGuard\drv\NetGuardTest.cer >> result.txt 2>&1
bcdedit /enum {current} | findstr /i testsigning >> result.txt 2>&1
echo --- driver --- >> result.txt
sc stop ngdrv >> result.txt 2>&1
sc delete ngdrv >> result.txt 2>&1
sc create ngdrv type= kernel start= demand binPath= C:\NetGuard\drv\ngdrv.sys >> result.txt 2>&1
sc start ngdrv >> result.txt 2>&1
sc query ngdrv >> result.txt 2>&1
echo --- netguard --- >> result.txt
NetGuard.exe initkey >> result.txt 2>&1
NetGuard.exe sign >> result.txt 2>&1
NetGuard.exe install >> result.txt 2>&1
sc start NetGuard >> result.txt 2>&1
powershell -NoProfile -Command "for($i=0;$i -lt 30;$i++){ Start-Sleep 1; $o=(& 'C:\NetGuard\NetGuard.exe' ctl status 2>&1) -join ' '; if($o -match 'filters='){ break } }" >> result.txt 2>&1
NetGuard.exe ctl apply >> result.txt 2>&1
echo waiting for NIC/NAT ... >> result.txt
ping -n 12 127.0.0.1 >nul
echo --- correct hash --- >> result.txt
ngblock.exe selftest >> result.txt 2>&1
echo correct_exit=%ERRORLEVEL% >> result.txt
echo --- tamper --- >> result.txt
copy /b ngblock.exe+tamper.bin ngblock.new >nul
move /y ngblock.new ngblock.exe >nul
ngblock.exe selftest >> result.txt 2>&1
echo tampered_exit=%ERRORLEVEL% >> result.txt
echo --- status --- >> result.txt
NetGuard.exe ctl status >> result.txt 2>&1
echo --- driver reg --- >> result.txt
reg query HKLM\SOFTWARE\NetGuard\DriverTest >> result.txt 2>&1
echo --- cleanup --- >> result.txt
NetGuard.exe ctl rollback >> result.txt 2>&1
sc stop NetGuard >> result.txt 2>&1
sc config NetGuard start= disabled >> result.txt 2>&1
sc stop ngdrv >> result.txt 2>&1
sc delete ngdrv >> result.txt 2>&1
echo --- ng.log --- >> result.txt
type C:\ProgramData\NetGuard\ng.log >> result.txt 2>&1
shutdown /s /t 20 /f
'@
[IO.File]::WriteAllText("$ng\drvtest.cmd", ($test -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding))
Remove-Item "$ng\result.txt" -Force -ErrorAction SilentlyContinue

# RunOnce + 自动登录
$sw = "$root\Windows\System32\config\SOFTWARE"
& reg load 'HKLM\W7DRV' $sw 2>&1 | Out-Null
if (-not $?) { throw 'cannot load Win7 SOFTWARE hive' }
$sysPol = 'HKLM:\W7DRV\Microsoft\Windows\CurrentVersion\Policies\System'
New-Item -Path $sysPol -Force | Out-Null
Set-ItemProperty $sysPol -Name EnableLUA -Value 0 -Type DWord
Set-ItemProperty $sysPol -Name DisableCAD -Value 1 -Type DWord
$wl = 'HKLM:\W7DRV\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $wl -Name DefaultUserName -Value 'freeze' -Type String
Set-ItemProperty $wl -Name DefaultPassword -Value '1' -Type String
Set-ItemProperty $wl -Name ForceAutoLogon -Value '1' -Type String
$sysHive = "$root\Windows\System32\config\SYSTEM"
& reg load 'HKLM\S7DRV' $sysHive 2>&1 | Out-Null
if ($?) {
    $cur = (Get-ItemProperty 'HKLM:\S7DRV\Select' -ErrorAction SilentlyContinue).Current
    if (-not $cur) { $cur = 1 }
    $comp = (Get-ItemProperty "HKLM:\S7DRV\ControlSet00$cur\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
    if ($comp) { Set-ItemProperty $wl -Name DefaultDomainName -Value $comp -Type String }
    [gc]::Collect(); Start-Sleep -Milliseconds 800
    & reg unload 'HKLM\S7DRV' 2>&1 | Out-Null
}
$runOnce = 'HKLM:\W7DRV\Microsoft\Windows\CurrentVersion\RunOnce'
New-Item -Path $runOnce -Force | Out-Null
Set-ItemProperty $runOnce -Name NgDrvTest -Value 'C:\NetGuard\drvtest.cmd' -Type String
[gc]::Collect(); Start-Sleep -Milliseconds 800
& reg unload 'HKLM\W7DRV' 2>&1 | Out-Null
L 'RunOnce installed'

[gc]::Collect()
Dismount-VHD -Path $vhd
Start-VM -Name 'Win7-Pro-x64'
L 'Win7 booting; phase1 enables testsigning and reboots; waiting for phase2 + shutdown ...'
# 第一次启动会 bcdedit + 重启，期间可能短暂 Off；先等 180 秒避开这个窗口。
Start-Sleep 180
for ($i = 0; $i -lt 40; $i++) {
    $st = (Get-VM -Name 'Win7-Pro-x64').State
    if ($i % 6 -eq 0) { L ('  T+' + (180 + $i * 10) + 's state=' + $st) }
    if ($st -eq 'Off') { L 'guest powered off'; break }
    Start-Sleep 10
}
if ((Get-VM -Name 'Win7-Pro-x64').State -ne 'Off') {
    L 'forcing power off'
    Stop-VM -Name 'Win7-Pro-x64' -TurnOff -Force -ErrorAction SilentlyContinue
    Start-Sleep 6
}

$v = Mount-VHD -Path $vhd -Passthru
Start-Sleep 2
$disk = $v | Get-Disk
$wp = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 1GB } | Select-Object -First 1
$root = "$((($wp | Get-Volume).DriveLetter)):"
$res = "$root\NetGuard\result.txt"
$txt = @()
if (Test-Path $res) {
    $txt = Get-Content $res -Encoding Default
    $txt | ForEach-Object { L ('  ' + $_) }
    Copy-Item $res (Join-Path $lab 'win7-drv-result.txt') -Force
} else { L 'result.txt MISSING' }
[gc]::Collect()
Dismount-VHD -Path $vhd

$all = ($txt -join "`n")
$correctSec = ''
$tamperSec = ''
if ($all -match '(?s)--- correct hash ---(.*?)--- tamper ---') { $correctSec = $Matches[1] }
if ($all -match '(?s)--- tamper ---(.*?)--- status ---') { $tamperSec = $Matches[1] }
$correctLeak = ($correctSec -match '\[LEAK \].*8\.8\.8\.8')
$correctOther = ($correctSec -match '\[LEAK \].*(114\.114|1\.1\.1\.1|180\.101)')
$tamperLeak = ($tamperSec -match '\[LEAK \]')
$drvRunning = ($all -match '(?s)ngdrv.*RUNNING')
$drvOk = ($all -match 'LastStep\s+REG_SZ\s+ok')
L ('RESULT correct_8.8.8.8=' + $correctLeak + ' correct_other_leak=' + $correctOther + ' tampered_leak=' + $tamperLeak + ' drv_running=' + $drvRunning + ' drv_ok=' + $drvOk)
if ($correctLeak -and -not $correctOther -and -not $tamperLeak -and $drvRunning -and $drvOk) { L 'RESULT: WIN7 DRIVER TEST OK' } else { L 'RESULT: WIN7 DRIVER TEST INCONCLUSIVE/FAIL' }
