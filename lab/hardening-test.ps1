param([string]$VmName = 'Win10-Pro-22H2')

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$lab = "$RepoRoot\lab"
$log = Join-Path $lab 'hardening-test.log'
$script:checks = @()
$script:fail = 0
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
'=== NetGuard hardening test @ ' + (Get-Date -Format o) + ' ===' | Set-Content -Path $log -Encoding UTF8

$ss = New-Object System.Security.SecureString
foreach ($ch in '1'.ToCharArray()) { $ss.AppendChar($ch) }
$ss.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential('freeze', $ss)
$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running') { Start-VM -Name $VmName }
$script:s = $null
for ($i = 0; $i -lt 40; $i++) {
    try { $script:s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop; break }
    catch { Start-Sleep 5 }
}
if (-not $script:s) { throw 'PowerShell Direct 连接失败' }
L ('PS Direct connected: ' + $VmName)

function RunExe([string]$path, [string]$argstr) {
    Invoke-Command -Session $script:s -ScriptBlock {
        param($p, $a)
        $o = Join-Path $env:TEMP 'nghard.out'; $e = Join-Path $env:TEMP 'nghard.err'
        Remove-Item $o, $e -ErrorAction SilentlyContinue
        $pr = Start-Process -FilePath $p -ArgumentList $a -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        $t = @()
        if (Test-Path $o) { $t += Get-Content $o -Encoding Default }
        if (Test-Path $e) { $t += Get-Content $e -Encoding Default }
        [pscustomobject]@{ ExitCode = $pr.ExitCode; Text = ($t -join "`n") }
    } -ArgumentList $path, $argstr
}
function Ctl([string]$cmd) {
    $r = RunExe 'C:\NetGuard\NetGuard.exe' ('ctl ' + $cmd)
    $vals = @{}
    foreach ($ln in ($r.Text -split "`r?`n")) { if ($ln -match '^([a-z_]+)=(.*)$') { $vals[$Matches[1]] = $Matches[2] } }
    [pscustomobject]@{ ExitCode = $r.ExitCode; Text = $r.Text; Vals = $vals }
}
function CurlExe([string]$exe, [string]$url) {
    return RunExe $exe ('-s -o NUL -m 6 --connect-timeout 4 ' + $url)
}

# ---------------------------------------------------------------- 1. 程序目录 ACL
Phase '1. program directory ACL'
$acl = Invoke-Command -Session $script:s -ScriptBlock {
    $bad = @()
    foreach ($a in (Get-Acl 'C:\NetGuard').Access) {
        try {
            $sid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if (($sid -eq 'S-1-5-11' -or $sid -eq 'S-1-5-32-545') -and
                ($a.FileSystemRights -match 'Write|Modify|FullControl|CreateFiles|AppendData')) {
                $bad += ($sid + '=' + $a.FileSystemRights)
            }
        } catch { }
    }
    [pscustomobject]@{ Bad = ($bad -join '; '); Text = ((& "$env:SystemRoot\System32\icacls.exe" 'C:\NetGuard') -join "`n") }
}
L ('  ' + $acl.Text)
Check 'program dir has no writable Users/Authenticated Users ACE' ([string]::IsNullOrEmpty($acl.Bad)) $acl.Bad

$stdWrite = Invoke-Command -Session $script:s -ScriptBlock {
    $p = 'C:\NetGuard\stdwrite2.txt'
    Remove-Item $p -Force -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\runas.exe" /trustlevel:0x20000 ('cmd /c echo x > ' + $p) 2>&1 | Out-Null
    Start-Sleep 2
    if (Test-Path $p) { 'WRITABLE' } else { 'not-written' }
}
L ('  restricted-token write -> ' + $stdWrite)
Check 'standard-user token cannot write program dir' ($stdWrite -eq 'not-written') $stdWrite

# ---------------------------------------------------------------- 2. 开发版试用门禁
Phase '2. development build trial gate'
$tr = RunExe 'C:\NetGuard\NetGuard.exe' 'trial'
L ('  trial: ' + (($tr.Text -split "`r?`n") -join ' | '))
Check 'trial gate disabled in dev build' ($tr.ExitCode -eq 0 -and $tr.Text -match '禁用') ('exit=' + $tr.ExitCode)

# ---------------------------------------------------------------- 3. 策略校验（StrictHash / LanAllow）
Phase '3. policy validation: StrictHash / LanAllow'
$bak = 'C:\ProgramData\NetGuard\policy.hardening.bak'
Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\ProgramData\NetGuard\policy.ini' 'C:\ProgramData\NetGuard\policy.hardening.bak' -Force
} | Out-Null

$badHash = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=Dummy
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[proc.1]
Name=bad-empty-hash
Path=C:\Windows\System32\notepad.exe
Sha256=
Endpoint=Dummy
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-bad-hash.ini'), ($badHash -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-bad-hash.ini') -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
L ('  strict-hash sign: exit=' + $r.ExitCode + ' ' + (($r.Text -split "`r?`n") -join ' | '))
Check 'StrictHash rejects enabled program with empty SHA-256' ($r.ExitCode -eq 4 -and $r.Text -match 'SHA-256') ('exit=' + $r.ExitCode)

$badLan = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
LanAllow=8.8.8.0/24
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=Dummy
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-bad-lan.ini'), ($badLan -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-bad-lan.ini') -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
L ('  lan opt-in sign: exit=' + $r.ExitCode + ' ' + (($r.Text -split "`r?`n") -join ' | '))
Check 'LanAllow without AllowLanAnyProcess is rejected' ($r.ExitCode -eq 4 -and $r.Text -match 'AllowLanAnyProcess') ('exit=' + $r.ExitCode)

Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\ProgramData\NetGuard\policy.hardening.bak' 'C:\ProgramData\NetGuard\policy.ini' -Force
} | Out-Null
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'verify'
Check 'restored policy verifies' ($r.ExitCode -eq 0) ('exit=' + $r.ExitCode)

# ---------------------------------------------------------------- 4. IPv6 业务过滤
Phase '4. IPv6 business endpoint'
Invoke-Command -Session $script:s -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\allow.exe' -Force
} | Out-Null
$hAllow = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\allow.exe').Text.Trim()
$v6 = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=V6Target
Cidr=2001:db8::10/128
Ports=443
Proto=TCP
Enable=1

[proc.1]
Name=allow
Path=C:\NetGuard\allow.exe
Sha256=$hAllow
Endpoint=V6Target
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-v6.ini'), ($v6 -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-v6.ini') -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
L ('  v6 apply: ' + (($ap.Text -split "`r?`n")[0]))
Check 'IPv6 endpoint accepted and filter created (6 filters = 2 deny + 2 loopback + DHCP + V6 business)' ($r.ExitCode -eq 0 -and $ap.Text -match 'OK filters=6') ($ap.Text)
$st = Ctl 'status'
Check 'IPv6 filter live' ($st.Vals['filters_live'] -eq '6') ('live=' + $st.Vals['filters_live'])

# ---------------------------------------------------------------- 5. 哈希窗口（5 秒快检）
Phase '5. hash revocation window'
$hPolicy = @"
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
Name=allow
Path=C:\NetGuard\allow.exe
Sha256=$hAllow
Endpoint=DNS
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-hash-window.ini'), ($hPolicy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-hash-window.ini') -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
Check 'hash-window policy applied (6 filters)' ($ap.Text -match 'OK filters=6') $ap.Text
$b = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:53/'
Check 'whitelisted allow.exe connects before tamper' ($b.ExitCode -ne 7) ('exit=' + $b.ExitCode)

Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\NetGuard\allow.exe' 'C:\NetGuard\allow.tampered.exe' -Force
    $fs = [IO.File]::Open('C:\NetGuard\allow.exe', 'Append')
    $bb = [Text.Encoding]::ASCII.GetBytes('NG-TAMPER-2')
    $fs.Write($bb, 0, $bb.Length); $fs.Close()
} | Out-Null
$imm = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:53/'
L ('  immediately after tamper: exit=' + $imm.ExitCode)
$revoked = $false
$sec = -1
$t0 = Get-Date
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep 2
    $st = Ctl 'status'
    L ("    t+{0,2}s filters={1}" -f (($i + 1) * 2), $st.Vals['filters'])
    if ([int]$st.Vals['filters'] -lt 6) { $revoked = $true; $sec = [int]((Get-Date) - $t0).TotalSeconds; break }
}
Check 'watchdog revokes tampered program within 12s' ($revoked -and $sec -le 12) ('after ' + $sec + 's')
$a = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:53/'
Check 'tampered program blocked after revocation' ($a.ExitCode -eq 7) ('exit=' + $a.ExitCode)

# ---------------------------------------------------------------- 6. 清理
Phase '6. cleanup'
Invoke-Command -Session $script:s -ScriptBlock {
    Remove-Item 'C:\NetGuard\allow.exe','C:\NetGuard\allow.tampered.exe','C:\NetGuard\stdwrite2.txt' -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\ProgramData\NetGuard\policy.hardening.bak' -Force -ErrorAction SilentlyContinue
} | Out-Null
$relax = @"
[general]
DefaultDeny=0
AllowDhcp=1
AllowLoopback=1
StrictHash=1
TempAllowUntil=0

[ep.1]
Name=placeholder
Cidr=10.10.10.10/32
Ports=8000
Proto=TCP
Enable=1
"@
[IO.File]::WriteAllText((Join-Path $lab 'policy-hardening-final.ini'), ($relax -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item (Join-Path $lab 'policy-hardening-final.ini') -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
$st = Ctl 'status'
L ('  final: ' + (($ap.Text -split "`r?`n")[0]) + ' live=' + $st.Vals['filters_live'])
Check 'enforcement disabled after test' ($st.Vals['filters_live'] -eq '0') ('live=' + $st.Vals['filters_live'])
Remove-PSSession $script:s -ErrorAction SilentlyContinue

Phase 'SUMMARY'
L ("total checks={0} failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
