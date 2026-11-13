param([string]$VmName = 'Win10-Pro-22H2')

$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'core-goal-test.log'
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

'=== NetGuard core-goal test @ ' + (Get-Date -Format o) + ' ===' | Set-Content -Path $log -Encoding UTF8

# ---------------------------------------------------------------- 连接客户机
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
        $o = Join-Path $env:TEMP 'ngcore.out'
        $e = Join-Path $env:TEMP 'ngcore.err'
        Remove-Item $o, $e -ErrorAction SilentlyContinue
        $pr = Start-Process -FilePath $p -ArgumentList $a -NoNewWindow -Wait -PassThru `
              -RedirectStandardOutput $o -RedirectStandardError $e
        $t = @()
        if (Test-Path $o) { $t += Get-Content $o -Encoding Default }
        if (Test-Path $e) { $t += Get-Content $e -Encoding Default }
        [pscustomobject]@{ ExitCode = $pr.ExitCode; Text = ($t -join "`n") }
    } -ArgumentList $path, $argstr
}
function Probe([string]$ip, [int]$port, [int]$timeout = 2500) {
    Invoke-Command -Session $script:s -ScriptBlock {
        param($ip, $port, $timeout)
        $sock = $null
        try {
            $sock = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork,
                                                  [Net.Sockets.SocketType]::Stream,
                                                  [Net.Sockets.ProtocolType]::Tcp)
            $ar = $sock.BeginConnect([Net.IPAddress]::Parse($ip), $port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($timeout)) { return 'TimedOut' }
            try { $sock.EndConnect($ar); return 'Connected' }
            catch { return $_.Exception.InnerException.SocketErrorCode.ToString() }
        } finally { if ($sock) { $sock.Close() } }
    } -ArgumentList $ip, $port, $timeout
}
function Ctl([string]$cmd) {
    $r = RunExe 'C:\NetGuard\NetGuard.exe' ('ctl ' + $cmd)
    $vals = @{}
    foreach ($ln in ($r.Text -split "`r?`n")) {
        if ($ln -match '^([a-z_]+)=(.*)$') { $vals[$Matches[1]] = $Matches[2] }
    }
    [pscustomobject]@{ ExitCode = $r.ExitCode; Text = $r.Text; Vals = $vals }
}
function CurlExe([string]$exe, [string]$url) {
    return RunExe $exe ('-s -o NUL -m 6 --connect-timeout 4 ' + $url)
}

$isAdmin = Invoke-Command -Session $script:s -ScriptBlock {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
L ('guest admin=' + $isAdmin)

# ---------------------------------------------------------------- 1. 当前状态 / 基线
Phase '1. baseline and test binaries'
$svc = Invoke-Command -Session $script:s -ScriptBlock {
    $s = Get-Service NetGuard -ErrorAction SilentlyContinue
    [pscustomobject]@{ Exists = [bool]$s; Status = if ($s) { $s.Status.ToString() } else { 'absent' } }
}
L ('service: exists=' + $svc.Exists + ' status=' + $svc.Status)
Check 'NetGuard service installed' ($svc.Exists -and $svc.Status -eq 'Running') ('status=' + $svc.Status)

Invoke-Command -Session $script:s -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
    New-Item -ItemType Directory -Path 'C:\ngtmp' -Force | Out-Null
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\allow.exe' -Force
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\allow2.exe' -Force
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\deny.exe' -Force
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\ngtmp\allow-copy.exe' -Force
    'test binaries deployed'
} | ForEach-Object { L ('  ' + $_) }

$st0 = Ctl 'status'
L ('status before: ' + (($st0.Text -split "`r?`n") -join ' | '))
$rb = Ctl 'rollback'
Check 'baseline rollback removes all filters' ($rb.Text -match 'OK') $rb.Text
Start-Sleep 2

$b = CurlExe 'C:\NetGuard\deny.exe' 'https://8.8.8.8:53/'
Check 'baseline unlisted binary can reach 8.8.8.8:53' ($b.ExitCode -ne 7) ('exit=' + $b.ExitCode)
$p0 = Probe '1.1.1.1' 443
Check 'baseline raw connect to 1.1.1.1:443 is not denied' ($p0 -ne 'AccessDenied') $p0

# ---------------------------------------------------------------- 2. 建立“策略生效前已存在”的 TCP 连接（宿主回显口）
Phase '2. pre-existing TCP connection to host listener'
$hostIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -like 'vEthernet (Default Switch)*' } |
           Select-Object -First 1).IPAddress
if (-not $hostIp) { $hostIp = '172.20.192.1' }
$listenPort = 45678
$ruleName = 'NG-Core-Goal-Test-45678'
try { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue } catch { }
try {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
        -LocalPort $listenPort -Action Allow -Profile Any | Out-Null
    L ('host listener firewall rule added, hostIp=' + $hostIp + ' port=' + $listenPort)
} catch { L ('WARN firewall rule failed: ' + $_.Exception.Message) }

$job = $null
$preConn = 'not-open'
try {
    $job = Start-Job -ScriptBlock {
        param($port)
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)
        $l.Start()
        try {
            while ($true) {
                $c = $l.AcceptTcpClient()
                $ns = $c.GetStream()
                $buf = New-Object byte[] 1024
                while (($n = $ns.Read($buf, 0, 1024)) -gt 0) {
                    $ns.Write($buf, 0, $n)
                    $ns.Flush()
                }
                $c.Close()
            }
        } finally { $l.Stop() }
    } -ArgumentList $listenPort
    Start-Sleep 3
    $preConn = Invoke-Command -Session $script:s -ScriptBlock {
        param($ip, $port)
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect($ip, $port)
            $ns = $c.GetStream()
            $b = [Text.Encoding]::ASCII.GetBytes('PING-BEFORE-POLICY')
            $ns.Write($b, 0, $b.Length); $ns.Flush()
            $buf = New-Object byte[] 128
            $n = $ns.Read($buf, 0, 128)
            $script:ngSock = $c
            $script:ngStream = $ns
            'OK:' + [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        } catch { 'ERR:' + $_.Exception.Message }
    } -ArgumentList $hostIp, $listenPort
} catch {
    $preConn = 'ERR:' + $_.Exception.Message
}
L ('pre-existing connection: ' + $preConn)
Check 'pre-policy host echo connection works (test harness)' ($preConn -like 'OK:*') $preConn

# ---------------------------------------------------------------- 3. 下发严格策略：只允许 allow.exe -> 8.8.8.8:53/TCP
Phase '3. strict policy: only allow.exe -> 8.8.8.8:53/TCP'
$hAllow = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\allow.exe').Text.Trim()
L ('allow.exe sha256=' + $hAllow)
Check 'guest SHA-256 computed' ($hAllow -match '^[0-9A-Fa-f]{64}$') ''

$policy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=AllowedTarget
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1

[proc.1]
Name=allowed
Path=C:\NetGuard\allow.exe
Sha256=$hAllow
Endpoint=AllowedTarget
Enable=1
"@
$polHost = Join-Path $lab 'policy-core-goal.ini'
[IO.File]::WriteAllText($polHost, ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item $polHost -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
L ('sign: ' + (($r.Text -split "`r?`n") -join ' | '))
Check 'policy signed by deployment key' ($r.ExitCode -eq 0) ('exit=' + $r.ExitCode)
$ap = Ctl 'apply'
L ('ctl apply: ' + ($ap.Text -split "`r?`n")[0])
Check 'strict policy applied (6 filters)' ($ap.Text -match 'OK filters=6') $ap.Text

# ---------------------------------------------------------------- 4. 核心矩阵：程序 × 地址 × 端口
Phase '4. enforcement matrix: process x address x port'
$a1 = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:53/'
$a2 = CurlExe 'C:\NetGuard\deny.exe'  'https://8.8.8.8:53/'
$a3 = CurlExe 'C:\NetGuard\allow2.exe' 'https://8.8.8.8:53/'
$a4 = CurlExe 'C:\ngtmp\allow-copy.exe' 'https://8.8.8.8:53/'
$a5 = CurlExe 'C:\NetGuard\allow.exe' 'https://1.1.1.1:443/'
$a6 = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:443/'
$a7 = CurlExe "$env:SystemRoot\System32\curl.exe" 'https://8.8.8.8:53/'
L ("  exits: allow->8.8.8.8:53={0}  deny->8.8.8.8:53={1}  same-dir-rename={2}  other-dir-copy={3}  allow->1.1.1.1:443={4}  allow->8.8.8.8:443={5}  system-curl={6}" -f `
    $a1.ExitCode, $a2.ExitCode, $a3.ExitCode, $a4.ExitCode, $a5.ExitCode, $a6.ExitCode, $a7.ExitCode)
Check 'whitelisted allow.exe -> allowed endpoint' ($a1.ExitCode -ne 7) ('exit=' + $a1.ExitCode)
Check 'unlisted deny.exe -> same allowed endpoint BLOCKED' ($a2.ExitCode -eq 7) ('exit=' + $a2.ExitCode)
Check 'renamed same binary in same dir BLOCKED' ($a3.ExitCode -eq 7) ('exit=' + $a3.ExitCode)
Check 'same binary copied to another dir BLOCKED' ($a4.ExitCode -eq 7) ('exit=' + $a4.ExitCode)
Check 'allowed program -> other address BLOCKED' ($a5.ExitCode -eq 7) ('exit=' + $a5.ExitCode)
Check 'allowed program -> other port BLOCKED' ($a6.ExitCode -eq 7) ('exit=' + $a6.ExitCode)
Check 'system curl -> allowed endpoint BLOCKED' ($a7.ExitCode -eq 7) ('exit=' + $a7.ExitCode)

$pDns = Probe '8.8.8.8' 53
$pCf  = Probe '1.1.1.1' 443
$pNewHost = Probe $hostIp $listenPort
L ("  raw socket: 8.8.8.8:53={0}  1.1.1.1:443={1}  host:{2}={3}" -f $pDns, $pCf, $listenPort, $pNewHost)
Check 'unlisted PowerShell process -> 8.8.8.8:53 denied' ($pDns -eq 'AccessDenied') $pDns
Check 'unlisted PowerShell process -> 1.1.1.1:443 denied' ($pCf -eq 'AccessDenied') $pCf
Check 'new connection to host listener denied too' ($pNewHost -eq 'AccessDenied') $pNewHost

# UDP / protocol binding (business rule is TCP only)
$udp = Invoke-Command -Session $script:s -ScriptBlock {
    try {
        $u = New-Object Net.Sockets.UdpClient
        $b = [Text.Encoding]::ASCII.GetBytes('netguard-udp')
        $n = $u.Send($b, $b.Length, '8.8.8.8', 53)
        $u.Close()
        'sent=' + $n
    } catch {
        $inner = $_.Exception.InnerException
        if ($inner -and $inner.SocketErrorCode) { 'err=' + $inner.SocketErrorCode } else { 'err=' + $_.Exception.Message }
    }
}
L ('  UDP send to 8.8.8.8:53 -> ' + $udp)
if ($udp -match 'AccessDenied') { Check 'UDP to allowed TCP endpoint is blocked by protocol binding' $true $udp }
else { Note ('UDP result is not a definitive WFP denial: ' + $udp) }

# ---------------------------------------------------------------- 5. 已建立连接是否继续可用
Phase '5. does default-deny terminate an already-established connection?'
$afterConn = Invoke-Command -Session $script:s -ScriptBlock {
    try {
        $ns = $script:ngStream
        if (-not $ns) { return 'NO-PRE-CONNECTION' }
        $b = [Text.Encoding]::ASCII.GetBytes('PING-AFTER-POLICY')
        $ns.Write($b, 0, $b.Length); $ns.Flush()
        $buf = New-Object byte[] 128
        $n = $ns.Read($buf, 0, 128)
        'OK:' + [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } catch { 'ERR:' + $_.Exception.Message }
}
L ('  traffic on pre-existing socket after policy apply: ' + $afterConn)
if ($afterConn -like 'OK:*') {
    Note 'PRE-EXISTING TCP CONNECTION SURVIVED policy apply (WFP ALE_AUTH_CONNECT only authorizes new connects).'
} else {
    Check 'pre-existing connection is cut by policy' ($afterConn -like 'ERR:*') $afterConn
}
Invoke-Command -Session $script:s -ScriptBlock {
    try { if ($script:ngStream) { $script:ngStream.Close() } } catch { }
    try { if ($script:ngSock) { $script:ngSock.Close() } } catch { }
    'pre-existing socket closed'
} | ForEach-Object { L ('  ' + $_) }

# ---------------------------------------------------------------- 6. 哈希巡检窗口（替换同名程序）
Phase '6. hash watchdog window: replace allow.exe with a different binary'
Invoke-Command -Session $script:s -ScriptBlock {
    Copy-Item 'C:\ngtmp\allow-copy.exe' 'C:\NetGuard\allow.exe' -Force
    $fs = [IO.File]::Open('C:\NetGuard\allow.exe', 'Append')
    $b = [Text.Encoding]::ASCII.GetBytes('NG-TAMPER')
    $fs.Write($b, 0, $b.Length); $fs.Close()
    'allow.exe replaced (curl + trailing bytes)'
} | ForEach-Object { L ('  ' + $_) }
$hTampered = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\allow.exe').Text.Trim()
Check 'tampered allow.exe hash differs' ($hTampered -ne $hAllow) $hTampered
$imm = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:53/'
L ('  immediately after replacement: exit=' + $imm.ExitCode)
if ($imm.ExitCode -ne 7) {
    Note 'TAMPERED BINARY STILL CONNECTED before the 30s hash watchdog (path-based app-id, hash checked periodically).'
} else {
    Note 'tampered binary was already blocked immediately (unexpected but safe).'
}
$revoked = $false
$revokeSeconds = -1
$t0 = Get-Date
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep 5
    $st = Ctl 'status'
    L ("    t+{0,3}s filters={1} live={2}" -f (($i + 1) * 5), $st.Vals['filters'], $st.Vals['filters_live'])
    if ([int]$st.Vals['filters'] -lt 6) { $revoked = $true; $revokeSeconds = [int]((Get-Date) - $t0).TotalSeconds; break }
}
Check 'watchdog revokes tampered program (6 -> 5 filters)' $revoked ('after ' + $revokeSeconds + 's')
$a8 = CurlExe 'C:\NetGuard\allow.exe' 'https://8.8.8.8:53/'
Check 'tampered program blocked after revocation' ($a8.ExitCode -eq 7) ('exit=' + $a8.ExitCode)
$polNow = Invoke-Command -Session $script:s -ScriptBlock { Get-Content 'C:\ProgramData\NetGuard\policy.ini' -Raw -Encoding UTF8 }
Check 'policy marks tampered entry Enable=0' ($polNow -match 'Name=allowed[\s\S]*?Enable=0') ''
$audit = Invoke-Command -Session $script:s -ScriptBlock { Get-Content 'C:\ProgramData\NetGuard\audit.log' -Encoding UTF8 | Select-Object -Last 12 }
$auditTxt = $audit -join "`n"
$audit | ForEach-Object { L ('  ' + $_) }
Check 'audit contains hash-changed alert' ($auditTxt -match 'hash-changed') ''

# ---------------------------------------------------------------- 7. LanAllow：任意进程访问整个网段
Phase '7. LanAllow is process-agnostic (configuration hole)'
$lanPolicy = @"
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
LanAllow=8.8.8.0/24
AllowLanAnyProcess=1
TempAllowUntil=0

[ep.1]
Name=AllowedTarget
Cidr=8.8.8.8/32
Ports=53
Proto=TCP
Enable=1
"@
[IO.File]::WriteAllText($polHost, ($lanPolicy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item $polHost -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
L ('  LanAllow=8.8.8.0/24 apply: ' + ($ap.Text -split "`r?`n")[0])
Check 'LanAllow policy applied (6 filters)' ($ap.Text -match 'OK filters=6') $ap.Text
$l1 = CurlExe 'C:\NetGuard\deny.exe' 'https://8.8.8.8:53/'
$l2 = CurlExe 'C:\NetGuard\deny.exe' 'https://1.1.1.1:443/'
L ("  unlisted deny.exe: ->8.8.8.8:53 exit={0}  ->1.1.1.1:443 exit={1}" -f $l1.ExitCode, $l2.ExitCode)
Check 'LanAllow lets ANY process reach the whole LAN/CIDR' ($l1.ExitCode -ne 7) ('exit=' + $l1.ExitCode)
Check 'default deny still blocks outside LanAllow' ($l2.ExitCode -eq 7) ('exit=' + $l2.ExitCode)
Note 'The sample initpolicy ships LanAllow=192.168.1.0/24; this grants every process every port on that LAN (including a router/proxy that can reach the Internet).'

# ---------------------------------------------------------------- 8. 标准用户能否改写白名单程序 / 策略
Phase '8. standard-user write access to program and policy'
$acl = Invoke-Command -Session $script:s -ScriptBlock {
    $ic = "$env:SystemRoot\System32\icacls.exe"
    [pscustomobject]@{
        Program = ((& $ic 'C:\NetGuard') -join "`n")
        Policy  = ((& $ic 'C:\ProgramData\NetGuard\policy.ini') -join "`n")
        Data    = ((& $ic 'C:\ProgramData\NetGuard') -join "`n")
    }
}
L ('  C:\NetGuard ACL:' + "`n" + $acl.Program)
L ('  policy.ini ACL:' + "`n" + $acl.Policy)
if ($acl.Program -match 'BUILTIN\\Users:.*\((M|W|F)\)' -or $acl.Program -match 'NT AUTHORITY\\Authenticated Users:.*\((M|W|F)\)') {
    Note 'A standard user appears able to modify C:\NetGuard (installer does not harden the program directory). Combined with the 30s hash window this is a practical bypass.'
} else {
    Note 'C:\NetGuard does not grant write to ordinary users (still verify per deployment path).'
}
$stdWrite = Invoke-Command -Session $script:s -ScriptBlock {
    $p = 'C:\NetGuard\stdwrite.txt'
    Remove-Item $p -Force -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\runas.exe" /trustlevel:0x20000 ('cmd /c echo stdwrite > ' + $p) 2>&1 | Out-Null
    Start-Sleep 2
    if (Test-Path $p) { 'WRITABLE' } else { 'not-written' }
}
L ('  restricted-token write attempt to C:\NetGuard -> ' + $stdWrite)
if ($stdWrite -eq 'WRITABLE') { Note 'Restricted token successfully wrote into C:\NetGuard; a standard user can replace the whitelisted exe.' }
else { Note 'Restricted-token write into C:\NetGuard failed (directory ACL is effective for this token).' }

# ---------------------------------------------------------------- 9. 收尾：关闭管控，恢复联网
Phase '9. cleanup: disable enforcement, restore Internet'
Invoke-Command -Session $script:s -ScriptBlock {
    Remove-Item 'C:\NetGuard\stdwrite.txt','C:\NetGuard\allow.exe','C:\NetGuard\allow2.exe','C:\NetGuard\deny.exe','C:\ngtmp\allow-copy.exe' -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\ngtmp' -Recurse -Force -ErrorAction SilentlyContinue
    'test binaries removed'
} | ForEach-Object { L ('  ' + $_) }

$relax = @"
[general]
DefaultDeny=0
AllowDhcp=1
AllowLoopback=1
TempAllowUntil=0

[ep.1]
Name=placeholder
Cidr=10.10.10.10/32
Ports=8000
Proto=TCP
Enable=1
"@
[IO.File]::WriteAllText($polHost, ($relax -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item $polHost -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
L ('  relax apply: ' + ($ap.Text -split "`r?`n")[0])
$st = Ctl 'status'
Check 'enforcement disabled at end (filters_live=0)' ($st.Vals['filters_live'] -eq '0') ('live=' + $st.Vals['filters_live'])
$pFree = Probe '1.1.1.1' 443
Check 'Internet restored after cleanup (not AccessDenied)' ($pFree -ne 'AccessDenied') $pFree

# ---------------------------------------------------------------- 10. 宿主侧清理
if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
try { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue } catch { }
Remove-PSSession $script:s -ErrorAction SilentlyContinue

Phase 'SUMMARY'
L ("total checks={0} failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
