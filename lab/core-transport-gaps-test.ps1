param([string]$VmName = 'Win10-Pro-22H2')

$ErrorActionPreference = 'Stop'
$lab = 'C:\src\NetGuard\lab'
$log = Join-Path $lab 'core-transport-gaps-test.log'
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
'=== NetGuard transport-gap test @ ' + (Get-Date -Format o) + ' ===' | Set-Content -Path $log -Encoding UTF8

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
        $o = Join-Path $env:TEMP 'nggap.out'; $e = Join-Path $env:TEMP 'nggap.err'
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

# ---------------------------------------------------------------- host echo servers
Phase '1. host echo servers'
$hostIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -like 'vEthernet (Default Switch)*' } |
           Select-Object -First 1).IPAddress
if (-not $hostIp) { $hostIp = '172.20.192.1' }
$tcp78log = Join-Path $lab 'tcp-echo-45678.log'
$tcp81log = Join-Path $lab 'tcp-echo-45681.log'
$udp79log = Join-Path $lab 'udp-echo-45679.log'
Remove-Item $tcp78log, $tcp81log, $udp79log -Force -ErrorAction SilentlyContinue
$rules = @('NG-Gap-TCP', 'NG-Gap-UDP')
foreach ($r in $rules) { try { Remove-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue } catch { } }
New-NetFirewallRule -DisplayName 'NG-Gap-TCP' -Direction Inbound -Protocol TCP -LocalPort 45678,45681 -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'NG-Gap-UDP' -Direction Inbound -Protocol UDP -LocalPort 45679 -Action Allow -Profile Any | Out-Null
$p78 = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'ng-tcp-echo.ps1'),'-Port','45678','-LogPath',$tcp78log) -WindowStyle Hidden -PassThru
$p81 = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'ng-tcp-echo.ps1'),'-Port','45681','-LogPath',$tcp81log) -WindowStyle Hidden -PassThru
$pU  = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'ng-udp-echo.ps1'),'-Port','45679','-LogPath',$udp79log) -WindowStyle Hidden -PassThru
Start-Sleep 3
L ('hostIp=' + $hostIp + ' tcp=45678/45681 udp=45679 started')
L ('  tcp78 log: ' + ((Get-Content $tcp78log -ErrorAction SilentlyContinue) -join ' | '))
L ('  tcp81 log: ' + ((Get-Content $tcp81log -ErrorAction SilentlyContinue) -join ' | '))
L ('  udp79 log: ' + ((Get-Content $udp79log -ErrorAction SilentlyContinue) -join ' | '))

# ---------------------------------------------------------------- baseline
Phase '2. baseline (no filters)'
$rb = Ctl 'rollback'
Check 'baseline rollback' ($rb.Text -match 'OK') $rb.Text
Start-Sleep 2

$tcpBase = Invoke-Command -Session $script:s -ScriptBlock {
    param($ip, $port)
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect($ip, $port)
        $ns = $c.GetStream()
        $b = [Text.Encoding]::ASCII.GetBytes('TCP-BEFORE')
        $ns.Write($b, 0, $b.Length); $ns.Flush()
        $buf = New-Object byte[] 128
        $n = $ns.Read($buf, 0, 128)
        $script:gapSock = $c; $script:gapStream = $ns
        'OK:' + [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } catch { 'ERR:' + $_.Exception.Message }
} -ArgumentList $hostIp, 45678
L ('  TCP 45678 before: ' + $tcpBase)
Check 'baseline TCP echo works' ($tcpBase -like 'OK:*') $tcpBase

$udpBase = Invoke-Command -Session $script:s -ScriptBlock {
    param($ip, $port)
    try {
        $u = New-Object Net.Sockets.UdpClient
        $u.Client.ReceiveTimeout = 3000
        $b = [Text.Encoding]::ASCII.GetBytes('UDP-BEFORE')
        $u.Send($b, $b.Length, $ip, $port) | Out-Null
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $r = $u.Receive([ref]$ep)
        $u.Close()
        'OK:' + [Text.Encoding]::ASCII.GetString($r)
    } catch { 'ERR:' + $_.Exception.Message }
} -ArgumentList $hostIp, 45679
L ('  UDP 45679 before: ' + $udpBase)
Check 'baseline UDP echo works' ($udpBase -like 'OK:*') $udpBase

$tcp81Base = Invoke-Command -Session $script:s -ScriptBlock {
    param($ip, $port)
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect($ip, $port)
        $ns = $c.GetStream()
        $b = [Text.Encoding]::ASCII.GetBytes('TCP81-BEFORE')
        $ns.Write($b, 0, $b.Length); $ns.Flush()
        $buf = New-Object byte[] 128
        $n = $ns.Read($buf, 0, 128)
        $c.Close()
        'OK:' + [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } catch { 'ERR:' + $_.Exception.Message }
} -ArgumentList $hostIp, 45681
L ('  TCP 45681 before: ' + $tcp81Base)
Check 'baseline second TCP port works' ($tcp81Base -like 'OK:*') $tcp81Base

$pingBase = Invoke-Command -Session $script:s -ScriptBlock {
    $r = & "$env:SystemRoot\System32\ping.exe" -n 2 -w 1000 8.8.8.8 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($r -join ' ') }
}
L ('  ping 8.8.8.8 before: exit=' + $pingBase.Exit + ' ' + $pingBase.Text)
$pingBaseOk = ($pingBase.Exit -eq 0)
if (-not $pingBaseOk) { Note 'baseline ICMP to 8.8.8.8 already fails; ICMP test will be inconclusive.' }

$dnsBase = Invoke-Command -Session $script:s -ScriptBlock {
    function DnsProbe([string]$server, [string]$name) {
        try {
            $q = New-Object System.Collections.Generic.List[byte]
            $q.AddRange([byte[]](0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00))
            foreach ($part in $name.Split('.')) { $q.Add([byte]$part.Length); $q.AddRange([Text.Encoding]::ASCII.GetBytes($part)) }
            $q.Add(0); $q.AddRange([byte[]](0x00,0x01,0x00,0x01))
            $u = New-Object Net.Sockets.UdpClient
            $u.Client.ReceiveTimeout = 3000
            $u.Send($q.ToArray(), $q.Count, $server, 53) | Out-Null
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $r = $u.Receive([ref]$ep)
            $u.Close()
            'OK:resp=' + $r.Length
        } catch { 'ERR:' + $_.Exception.Message }
    }
    DnsProbe '8.8.8.8' 'example.com'
}
L ('  DNS UDP 8.8.8.8:53 before: ' + $dnsBase)
$dnsBaseOk = ($dnsBase -like 'OK:*')
if (-not $dnsBaseOk) { Note 'baseline UDP DNS query to 8.8.8.8 fails; DNS result will be inconclusive.' }

# ---------------------------------------------------------------- apply strict policy
Phase '3. apply strict default-deny policy'
Invoke-Command -Session $script:s -ScriptBlock {
    New-Item -ItemType Directory -Path 'C:\NetGuard' -Force | Out-Null
    Copy-Item "$env:SystemRoot\System32\curl.exe" 'C:\NetGuard\allow.exe' -Force
    'allow.exe recreated'
} | ForEach-Object { L ('  ' + $_) }
$hAllow = (RunExe 'C:\NetGuard\NetGuard.exe' 'hash C:\NetGuard\allow.exe').Text.Trim()
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
$polHost = Join-Path $lab 'policy-transport-gaps.ini'
[IO.File]::WriteAllText($polHost, ($policy -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Copy-Item $polHost -ToSession $script:s -Destination 'C:\ProgramData\NetGuard\policy.ini' -Force
$r = RunExe 'C:\NetGuard\NetGuard.exe' 'sign'
$ap = Ctl 'apply'
L ('  sign exit=' + $r.ExitCode + '  apply: ' + ($ap.Text -split "`r?`n")[0])
Check 'strict policy applied (6 filters)' ($ap.Text -match 'OK filters=6') $ap.Text

# ---------------------------------------------------------------- post-policy transport matrix
Phase '4. post-policy: TCP / UDP / ICMP / DNS'
$newTcp = Probe $hostIp 45681
L ('  new TCP 45681 after: ' + $newTcp)
Check 'new TCP connection to unlisted host port denied' ($newTcp -eq 'AccessDenied') $newTcp

$udpAfter = Invoke-Command -Session $script:s -ScriptBlock {
    param($ip, $port)
    try {
        $u = New-Object Net.Sockets.UdpClient
        $u.Client.ReceiveTimeout = 3000
        $b = [Text.Encoding]::ASCII.GetBytes('UDP-AFTER-POLICY')
        $u.Send($b, $b.Length, $ip, $port) | Out-Null
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $r = $u.Receive([ref]$ep)
        $u.Close()
        'OK:' + [Text.Encoding]::ASCII.GetString($r)
    } catch { 'ERR:' + $_.Exception.Message }
} -ArgumentList $hostIp, 45679
L ('  UDP 45679 after: ' + $udpAfter)
$udpHostLog = (Get-Content $udp79log -ErrorAction SilentlyContinue) -join ' | '
L ('  host UDP log: ' + $udpHostLog)
if ($udpAfter -like 'OK:*' -or $udpHostLog -match 'UDP-AFTER-POLICY') {
    Note 'UDP SEND WAS NOT BLOCKED by default-deny (WFP ALE_AUTH_CONNECT does not cover unconnected UDP sendto in this test).'
    Check 'UDP datagram blocked after policy' $false $udpAfter
} else {
    Check 'UDP datagram blocked after policy' $true ('send/recv=' + $udpAfter)
}

$tcpAfter = Invoke-Command -Session $script:s -ScriptBlock {
    try {
        $ns = $script:gapStream
        if (-not $ns) { return 'NO-PRE-CONNECTION' }
        $b = [Text.Encoding]::ASCII.GetBytes('TCP-AFTER-POLICY')
        $ns.Write($b, 0, $b.Length); $ns.Flush()
        $buf = New-Object byte[] 128
        $n = $ns.Read($buf, 0, 128)
        'OK:' + [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } catch { 'ERR:' + $_.Exception.Message }
}
L ('  existing TCP 45678 after: ' + $tcpAfter)
$tcpHostLog = (Get-Content $tcp78log -ErrorAction SilentlyContinue) -join ' | '
L ('  host TCP 45678 log: ' + $tcpHostLog)
if ($tcpHostLog -match 'TCP-AFTER-POLICY' -or $tcpAfter -like 'OK:*') {
    Note 'PRE-EXISTING TCP CONNECTION CARRIED DATA AFTER POLICY APPLY (host saw TCP-AFTER-POLICY and/or client read an echo).'
    Check 'pre-existing TCP connection is terminated' $false $tcpAfter
} else {
    Check 'pre-existing TCP connection is terminated' $true $tcpAfter
}
Invoke-Command -Session $script:s -ScriptBlock {
    try { if ($script:gapStream) { $script:gapStream.Close() } } catch { }
    try { if ($script:gapSock) { $script:gapSock.Close() } } catch { }
    'sockets closed'
} | ForEach-Object { L ('  ' + $_) }

$pingAfter = Invoke-Command -Session $script:s -ScriptBlock {
    $r = & "$env:SystemRoot\System32\ping.exe" -n 2 -w 1000 8.8.8.8 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($r -join ' ') }
}
L ('  ping 8.8.8.8 after: exit=' + $pingAfter.Exit + ' ' + $pingAfter.Text)
if ($pingBaseOk) {
    if ($pingAfter.Exit -eq 0) {
        Note 'ICMP ECHO STILL WORKS after default-deny (any process can ping any host).'
        Check 'ICMP blocked after policy' $false $pingAfter.Text
    } else {
        Check 'ICMP blocked after policy' $true $pingAfter.Text
    }
} else { Note 'ICMP baseline failed; inconclusive.' }

$dnsAfter = Invoke-Command -Session $script:s -ScriptBlock {
    function DnsProbe([string]$server, [string]$name) {
        try {
            $q = New-Object System.Collections.Generic.List[byte]
            $q.AddRange([byte[]](0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00))
            foreach ($part in $name.Split('.')) { $q.Add([byte]$part.Length); $q.AddRange([Text.Encoding]::ASCII.GetBytes($part)) }
            $q.Add(0); $q.AddRange([byte[]](0x00,0x01,0x00,0x01))
            $u = New-Object Net.Sockets.UdpClient
            $u.Client.ReceiveTimeout = 3000
            $u.Send($q.ToArray(), $q.Count, $server, 53) | Out-Null
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $r = $u.Receive([ref]$ep)
            $u.Close()
            'OK:resp=' + $r.Length
        } catch { 'ERR:' + $_.Exception.Message }
    }
    DnsProbe '8.8.8.8' 'example.com'
}
L ('  DNS UDP 8.8.8.8:53 after: ' + $dnsAfter)
if ($dnsBaseOk) {
    if ($dnsAfter -like 'OK:*') {
        Note 'DNS (UDP 53) STILL WORKS without AllowDnsServer after default-deny.'
        Check 'DNS blocked after policy' $false $dnsAfter
    } else {
        Check 'DNS blocked after policy' $true $dnsAfter
    }
} else { Note 'DNS baseline failed; inconclusive.' }

# ---------------------------------------------------------------- cleanup
Phase '5. cleanup'
Invoke-Command -Session $script:s -ScriptBlock {
    Remove-Item 'C:\NetGuard\allow.exe' -Force -ErrorAction SilentlyContinue
    'test binary removed'
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
$st = Ctl 'status'
L ('  relax apply: ' + ($ap.Text -split "`r?`n")[0] + '  live=' + $st.Vals['filters_live'])
Check 'enforcement disabled at end' ($st.Vals['filters_live'] -eq '0') ('live=' + $st.Vals['filters_live'])

foreach ($p in @($p78, $p81, $pU)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
foreach ($r in $rules) { try { Remove-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue } catch { } }
Remove-PSSession $script:s -ErrorAction SilentlyContinue

Phase 'SUMMARY'
L ("total checks={0} failed={1}" -f $script:checks.Count, $script:fail)
$script:checks | ForEach-Object { L ("  [{0}] {1} {2}" -f $(if ($_.Ok) { 'OK' } else { 'XX' }), $_.Name, $_.Detail) }
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
