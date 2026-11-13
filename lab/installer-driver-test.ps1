param([string]$VmName = 'Win10-Pro-22H2')

$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'installer-driver-test.log'
$script:checks = @()
$script:fail = 0
function L([string]$m) { $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content $log $line -Encoding UTF8; Write-Host $line }
function Phase([string]$t) { L ''; L ('==== ' + $t + ' ====') }
function Check([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { L ('PASS  ' + $n + '  ' + $d) } else { L ('FAIL  ' + $n + '  ' + $d); $script:fail++ }
    $script:checks += [pscustomobject]@{ Name = $n; Ok = $ok; Detail = $d }
}
'=== installer + driver e2e ' + (Get-Date -Format o) + ' ===' | Set-Content $log -Encoding UTF8

# 签名驱动（测试证书）
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq 'CN=NetGuardTest' } | Select-Object -First 1
if (-not $cert) { throw 'CN=NetGuardTest cert missing; run lab/ngdrv-test.ps1 first' }
$signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
& $signtool sign /fd sha256 /sm /s My /sha1 $cert.Thumbprint 'C:\src\NetGuard\drv\out\ngdrv.sys' | Out-Null
L 'driver signed SHA-256'

# VM
$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running') { Start-VM -Name $VmName }
$s = $null
for ($i = 0; $i -lt 40; $i++) {
    try { $s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop; break } catch { Start-Sleep 5 }
}
if (-not $s) { throw 'PS Direct failed' }
L 'PS Direct connected'

Phase '1. clean old app/driver'
$clean = Invoke-Command -Session $s -ScriptBlock {
    foreach ($svc in @('NetGuard','ngdrv')) {
        & sc.exe stop $svc 2>&1 | Out-Null
        & sc.exe delete $svc 2>&1 | Out-Null
    }
    Get-Process NetGuard,NetGuardUI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Remove-Item 'C:\NetGuard','C:\ProgramData\NetGuard' -Recurse -Force -ErrorAction SilentlyContinue
    & reg.exe delete 'HKLM\SOFTWARE\NetGuard' /f 2>&1 | Out-Null
    [pscustomobject]@{
        Svc = [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
        Drv = [bool](Get-Service ngdrv -ErrorAction SilentlyContinue)
        Dir = Test-Path 'C:\NetGuard'
        Data = Test-Path 'C:\ProgramData\NetGuard'
    }
}
Check 'old NetGuard service gone' (-not $clean.Svc) ''
Check 'old ngdrv service gone' (-not $clean.Drv) ''
Check 'old program/data dirs gone' ((-not $clean.Dir) -and (-not $clean.Data)) ''

Phase '2. deploy build + installer + driver'
Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Path 'C:\NetGuard\drv' -Force | Out-Null } | Out-Null
foreach ($f in @(
    @{ Src='C:\src\NetGuard\build\NetGuard.exe'; Dst='C:\NetGuard\NetGuard.exe' },
    @{ Src='C:\src\NetGuard\build\NetGuardUI.exe'; Dst='C:\NetGuard\NetGuardUI.exe' },
    @{ Src='C:\src\NetGuard\install-netguard.ps1'; Dst='C:\NetGuard\install-netguard.ps1' },
    @{ Src='C:\src\NetGuard\uninstall-netguard.ps1'; Dst='C:\NetGuard\uninstall-netguard.ps1' },
    @{ Src='C:\src\NetGuard\drv\out\ngdrv.sys'; Dst='C:\NetGuard\drv\ngdrv.sys' },
    @{ Src=(Join-Path $lab 'NetGuardTest.cer'); Dst='C:\NetGuard\drv\NetGuardTest.cer' }
)) { Copy-Item $f.Src -ToSession $s -Destination $f.Dst -Force }
L 'files deployed'

$prep = Invoke-Command -Session $s -ScriptBlock {
    & certutil.exe -addstore -f Root 'C:\NetGuard\drv\NetGuardTest.cer' 2>&1 | Out-Null
    & certutil.exe -addstore -f TrustedPublisher 'C:\NetGuard\drv\NetGuardTest.cer' 2>&1 | Out-Null
    (& bcdedit.exe /enum '{current}' 2>&1) -join "`n"
}
L ('testsigning block: ' + (($prep -split "`r?`n" | Where-Object { $_ -match 'testsigning|nointegrity' }) -join ' | '))
Check 'testsigning on' ($prep -match 'testsigning\s+Yes') ''

Phase '3. run install-netguard.ps1 -InstallDriver'
$r = Invoke-Command -Session $s -ScriptBlock {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\install-netguard.ps1' -InstallDriver 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($o -join "`n") }
}
L ('installer exit=' + $r.Exit)
$r.Text -split "`r?`n" | Where-Object { $_ -match '\[\*\]|\[x\]|\[!\]|服务状态|驱动状态|完成' } | ForEach-Object { L ('  ' + $_) }
Check 'install script exit=0' ($r.Exit -eq 0) ('exit=' + $r.Exit)

$st = Invoke-Command -Session $s -ScriptBlock {
    $n = Get-Service NetGuard -ErrorAction SilentlyContinue
    $d = Get-Service ngdrv -ErrorAction SilentlyContinue
    $out = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep 2
        $out = (& 'C:\NetGuard\NetGuard.exe' ctl status 2>&1) -join "`n"
        if ($out -match 'filters=') { break }
    }
    [pscustomobject]@{
        NetGuard = if ($n) { $n.Status.ToString() } else { 'absent' }
        Driver = if ($d) { $d.Status.ToString() } else { 'absent' }
        Status = $out
        Acl = ((& "$env:SystemRoot\System32\icacls.exe" 'C:\NetGuard') -join "`n")
    }
}
Check 'NetGuard service Running' ($st.NetGuard -eq 'Running') $st.NetGuard
Check 'ngdrv driver Running' ($st.Driver -eq 'Running') $st.Driver
$vals = @{}
foreach ($ln in ($st.Status -split "`r?`n")) { if ($ln -match '^([a-z_]+)=(.*)$') { $vals[$Matches[1]] = $Matches[2] } }
L ('status: ' + (($st.Status -split "`r?`n") -join ' | '))
Check 'filters>=6 after install' ([int]$vals['filters'] -ge 6) ('filters=' + $vals['filters'])
Check 'key/hmac valid' ($vals['key_ok'] -eq '1' -and $vals['hmac_ok'] -eq '1') ''
Check 'trial disabled' ($vals['trial_disabled'] -eq '1') ''
Check 'program dir Users read-only' ($st.Acl -match 'Users:\(OI\)\(CI\)\(RX\)') ''
$nglog = Invoke-Command -Session $s -ScriptBlock { Get-Content 'C:\ProgramData\NetGuard\ng.log' -Tail 30 -ErrorAction SilentlyContinue }
Check 'service sent driver whitelist' (($nglog -join "`n") -match 'drv:') ''

Phase '4. driver enforcement after installer'
$h = Invoke-Command -Session $s -ScriptBlock {
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\ngblock.exe' -Force
    (& 'C:\NetGuard\NetGuard.exe' hash 'C:\NetGuard\ngblock.exe').Trim()
}
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
[IO.File]::WriteAllText((Join-Path $lab 'policy-installer-driver.ini'), ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-installer-driver.ini') -ToSession $s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$ap = Invoke-Command -Session $s -ScriptBlock {
    & 'C:\NetGuard\NetGuard.exe' sign 2>&1 | Out-Null
    (& 'C:\NetGuard\NetGuard.exe' ctl apply 2>&1) -join ' '
}
L ('apply: ' + $ap)
Check 'test policy applied' ($ap -match 'OK filters=6') $ap

$r1 = Invoke-Command -Session $s -ScriptBlock {
    $c = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
$r2 = Invoke-Command -Session $s -ScriptBlock {
    $c = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://114.114.114.114:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
$r3 = Invoke-Command -Session $s -ScriptBlock {
    $fs = [IO.File]::Open('C:\NetGuard\ngblock.exe', 'Append')
    $b = [Text.Encoding]::ASCII.GetBytes('NG-INST-TAMPER')
    $fs.Write($b, 0, $b.Length); $fs.Close()
    $c = & 'C:\NetGuard\ngblock.exe' -s -o NUL -m 5 --connect-timeout 3 https://8.8.8.8:53/ 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($c -join ' ') }
}
L ('correct=' + $r1.Exit + ' other=' + $r2.Exit + ' tampered=' + $r3.Exit)
Check 'correct hash allowed' ($r1.Exit -ne 7) ('exit=' + $r1.Exit)
Check 'other destination blocked by user-mode default deny' ($r2.Exit -eq 7) ('exit=' + $r2.Exit)
Check 'tampered binary blocked by driver' ($r3.Exit -eq 7) ('exit=' + $r3.Exit)

Phase '5. uninstall'
$u = Invoke-Command -Session $s -ScriptBlock {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\NetGuard\uninstall-netguard.ps1' 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($o -join "`n") }
}
L ('uninstall exit=' + $u.Exit)
$u.Text -split "`r?`n" | Where-Object { $_ -match '\[\*\]|\[!\]' } | ForEach-Object { L ('  ' + $_) }
Check 'uninstall exit=0' ($u.Exit -eq 0) ('exit=' + $u.Exit)
$post = Invoke-Command -Session $s -ScriptBlock {
    [pscustomobject]@{
        Svc = [bool](Get-Service NetGuard -ErrorAction SilentlyContinue)
        Drv = [bool](Get-Service ngdrv -ErrorAction SilentlyContinue)
        Proc = @(Get-Process NetGuard -ErrorAction SilentlyContinue).Count
        Filters = if (Test-Path 'C:\ProgramData\NetGuard\filters.txt') { (Get-Content 'C:\ProgramData\NetGuard\filters.txt').Count } else { -1 }
    }
}
Check 'after uninstall: NetGuard service gone' (-not $post.Svc) ''
Check 'after uninstall: ngdrv driver gone' (-not $post.Drv) ''
Check 'after uninstall: no process' ($post.Proc -eq 0) ('count=' + $post.Proc)
Check 'after uninstall: filters.txt empty' ($post.Filters -eq 0) ('lines=' + $post.Filters)
$net = Invoke-Command -Session $s -ScriptBlock { (Test-NetConnection 8.8.8.8 -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue) }
Check 'after uninstall: network restored' ($net -eq $true) ('tnc=' + $net)

Remove-PSSession $s -ErrorAction SilentlyContinue
Phase 'SUMMARY'
L ("total checks={0} failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
